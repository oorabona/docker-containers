# 🏗️ Workflow Architecture - Docker Containers Automation

## 📊 Overview

Ce document décrit l'architecture complète du système d'automatisation des containers Docker, incluant la détection des versions, le build, le push et la mise à jour du dashboard.

## 🔄 Flux Complet d'Automatisation

```
┌─────────────────────────────────────────────────────────────────────┐
│                    UPSTREAM VERSION MONITOR                          │
│                    (Cron: 2x/jour)                                  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ check-upstream-      │
                    │ versions action      │
                    │                      │
                    │ Compare:             │
                    │ upstream vs          │
                    │ oorabona/* registry  │
                    └──────────┬───────────┘
                               │
                 ┌─────────────┴─────────────┐
                 │                           │
          ┌──────▼────────┐         ┌───────▼────────┐
          │ No Updates    │         │ Updates Found  │
          │ Available     │         │                │
          └───────────────┘         └───────┬────────┘
                                            │
                                            ▼
                                ┌───────────────────────┐
                                │ classify-version-     │
                                │ change.sh             │
                                │                       │
                                │ Détermine: major vs   │
                                │ minor change          │
                                └───────┬───────────────┘
                                        │
                          ┌─────────────┴────────────┐
                          │                          │
                   ┌──────▼──────┐          ┌────────▼────────┐
                   │ MAJOR       │          │ MINOR/PATCH     │
                   │             │          │                 │
                   │ - Create PR │          │ - Create PR     │
                   │ - Manual    │          │ - Auto-merge    │
                   │   review    │          │   enabled       │
                   └─────────────┘          └────────┬────────┘
                                                     │
                                                     ▼
                                            ┌────────────────┐
                                            │ PR Auto-Merged │
                                            │ to master      │
                                            └────────┬───────┘
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│                         AUTO-BUILD WORKFLOW                             │
│                 (Trigger: push to master)                              │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ detect-containers    │
                    │ action               │
                    │                      │
                    │ Détecte containers   │
                    │ modifiés via git diff│
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ build-container      │
                    │ action               │
                    │                      │
                    │ Matrix strategy:     │
                    │ Build each container │
                    └──────────┬───────────┘
                               │
                 ┌─────────────┴────────────┐
                 │                          │
          ┌──────▼────────┐        ┌────────▼─────────┐
          │ Build FAILED  │        │ Build SUCCESS    │
          │               │        │                  │
          │ - Retry once  │        │ - Push to GHCR   │
          │ - Exit on     │        │ - Push to Docker │
          │   failure     │        │   Hub            │
          └───────────────┘        └────────┬─────────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ update-dashboard│
                                   │ workflow        │
                                   │                 │
                                   │ ONLY if:        │
                                   │ - Build success │
                                   │ - Push to master│
                                   └────────┬────────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ Generate        │
                                   │ Dashboard       │
                                   │                 │
                                   │ - Analyse       │
                                   │   registries    │
                                   │ - Build Jekyll  │
                                   │ - Deploy to     │
                                   │   GitHub Pages  │
                                   └─────────────────┘
```

## 🎯 Détail des Workflows

### 1. upstream-monitor.yaml

**Déclencheur** :
- Cron : `0 6,18 * * *` (6h et 18h UTC, 2x/jour)
- Manual : `workflow_dispatch`

**Processus** :
1. **check-upstream-versions** : Utilise le script `make check-updates` pour :
   - Lire `version.sh` de chaque container (version upstream)
   - Comparer avec `oorabona/*` sur Docker Hub/GHCR (version publiée)
   - Retourner JSON avec containers nécessitant une mise à jour

2. **classify-version-change** : Détermine le type de changement :
   - `major` : Changement de version majeure ou nouveau container
   - `minor` : Changement mineur/patch

3. **Create Pull Request** : Crée une PR avec :
   - Fichier `LAST_REBUILD.md` comme marker
   - Titre indiquant le type (🔄 Major ou 🚀 Minor)
   - Description avec détails du changement

4. **Auto-merge** (si minor) : Active l'auto-merge sur la PR

**Outputs** :
- PR créée et éventuellement auto-merged
- `LAST_REBUILD.md` contient l'historique du rebuild

### 2. auto-build.yaml

**Déclencheur** :
- `pull_request` : Sur modifications de Dockerfile, version.sh, etc.
- `push` (master) : Après merge d'une PR
- `workflow_call` : Appelé par d'autres workflows
- `workflow_dispatch` : Trigger manuel

**Processus** :

#### Job 1 : detect-containers
- Utilise `.github/actions/detect-containers`
- Stratégies de détection :
  - **workflow_dispatch avec force_rebuild** : Tous les containers
  - **workflow_dispatch avec container spécifique** : Container ciblé
  - **push/PR** : Git diff pour détecter fichiers modifiés
  - **workflow_call** : Container passé en input

#### Job 2 : build-and-push
- Matrice : Un job par container détecté
- Étapes :
  1. **Checkout** : Clone le repo
  2. **Login registries** : Docker Hub + GHCR (si push vers master)
  3. **Build** : Utilise `.github/actions/build-container`
     - Sur PR : Build local uniquement (`--load`)
     - Sur push master : Build + Push (`--push`)
  4. **Retry** : Si échec, retry une fois
  5. **Summary** : Génère résumé GitHub avec liens vers images

**Comportement selon event** :
- **PR** : BUILD uniquement (test de validité)
- **Push master** : BUILD + PUSH (déploiement)

#### Job 3 : update-dashboard
**Condition stricte** :
```yaml
if: |
  always() && 
  needs.build-and-push.result == 'success' &&
  github.event_name == 'push' &&
  github.ref == 'refs/heads/master'
```

**Pourquoi cette condition ?**
- Évite les updates pendant les PRs (test mode)
- Garantit que seuls les builds réussis déclenchent le dashboard
- S'assure qu'on est sur master (déploiement production)

### 3. update-dashboard.yaml

**Déclencheur** :
- `workflow_call` : Appelé par auto-build
- `push` (master) : Sur modifications docs/ ou *.md
- `workflow_dispatch` : Trigger manuel

**Processus** :

#### Job 1 : build
1. **Generate dashboard** : Exécute `generate-dashboard.sh`
   - Parcourt tous les containers
   - Appelle `helpers/latest-docker-tag oorabona/<container>` pour version publiée
   - Appelle `version.sh` pour version upstream
   - Compare et détermine le statut (Up to date / Update available / Not published)
   - Génère `index.md` avec Jekyll includes

2. **Build Jekyll** : Compile le site statique
   - Utilise `_config.yml` de `docs/site/`
   - Templates dans `_layouts/` et `_includes/`
   - Génère `./_site`

3. **Upload artifact** : Prépare le site pour déploiement

#### Job 2 : deploy
**Condition** :
```yaml
if: github.event_name == 'push' || 
    github.event_name == 'workflow_dispatch' || 
    (github.event_name == 'workflow_call' && github.ref == 'refs/heads/master')
```

- Déploie sur GitHub Pages
- URL : https://oorabona.github.io/docker-containers/

## 📝 Fichier LAST_REBUILD.md

### Utilité
- **Marker pour PR** : GitHub requiert au moins 1 fichier modifié pour créer une PR
- **Trigger workflow** : Présent dans les `paths` d'`auto-build.yaml`
- **Documentation** : Historique des rebuilds avec métadonnées

### Format
```markdown
# Container Rebuild Information

**Container:** ansible  
**Version Change:** 12.0.0 → 12.1.0  
**Change Type:** minor  
**Rebuild Date:** 2025-10-23T14:23:45Z  
**Triggered By:** Upstream Monitor (automated)  
**Reason:** New upstream version detected  

## Build Status
This file triggers the auto-build workflow when merged to master.
Build status will be available in GitHub Actions after merge.

---
*Auto-generated by docker-containers automation system*
```

### Cycle de vie
1. **Création** : Par `upstream-monitor` lors de détection d'update
2. **Commit** : Dans la PR automatique
3. **Merge** : Avec la PR (trigger `auto-build`)
4. **Persistence** : Reste dans le repo comme historique

**Note** : Contrairement à une idée initiale, ce n'est **PAS** un fichier `.version` cumulatif, mais un marker par rebuild.

## 🔍 Source de Vérité pour les Versions

### Versions Upstream (source)
- **Défini dans** : `<container>/version.sh`
- **Stratégies** :
  - Docker Hub API : `helpers/latest-docker-tag owner/image "pattern"`
  - PyPI : `helpers/python-tags` → `get_pypi_latest_version package`
  - GitHub Releases : API GitHub
  - Custom : Script spécifique au container

### Versions Publiées (ce qu'on a déployé)
- **Source** : `oorabona/*` sur Docker Hub et GHCR
- **Méthode** : `helpers/latest-docker-tag oorabona/<container> "pattern"`
- **Pattern** : Défini via `version.sh --registry-pattern`

### Comparaison
```bash
# Dans make check-updates et generate-dashboard.sh
current=$(helpers/latest-docker-tag "oorabona/$container" "$pattern")
latest=$(cd $container && ./version.sh)

if [ "$current" != "$latest" ]; then
  # Update available!
fi
```

**Pourquoi oorabona/* et non l'upstream ?**
- On compare notre version publiée vs l'upstream
- Permet de savoir si **nous** devons rebuilder
- Évite les rebuilds inutiles si déjà à jour

## 🎯 Cas d'Usage

### Nouveau Container
1. **Détection** : `current_version = "no-published-version"`
2. **Classification** : Traité comme `major` (review requise)
3. **PR** : Créée sans auto-merge
4. **Review** : Manuelle obligatoire
5. **Merge** : Déclenche build + dashboard

### Update Minor
1. **Détection** : `current 1.0.0 → latest 1.0.1`
2. **Classification** : `minor`
3. **PR** : Créée avec auto-merge enabled
4. **Auto-merge** : Après checks réussis
5. **Build** : Automatique sur master
6. **Dashboard** : Mis à jour automatiquement

### Update Major
1. **Détection** : `current 1.0.0 → latest 2.0.0`
2. **Classification** : `major`
3. **PR** : Créée sans auto-merge
4. **Review** : Manuelle (breaking changes possibles)
5. **Merge** : Manuel après validation
6. **Build** : Automatique sur master
7. **Dashboard** : Mis à jour automatiquement

### Force Rebuild (manual)
1. **Trigger** : `workflow_dispatch` avec `force_rebuild: true`
2. **Detection** : Ignore la comparaison de versions
3. **Build** : Tous les containers (ou spécifique)
4. **Dashboard** : Mis à jour si push vers master

## 🐛 Troubleshooting

### Dashboard pas à jour après build
**Symptôme** : Container publié sur Docker Hub mais dashboard affiche ancienne version

**Causes possibles** :
1. ❌ Build fait depuis une PR (pas de push vers master)
2. ❌ Condition `update-dashboard` pas remplie
3. ❌ Cache Docker Hub API (délai propagation)

**Solution** :
```bash
# Vérifier le workflow run
gh run list --workflow=auto-build.yaml

# Vérifier si update-dashboard a été appelé
gh run view <run-id> --log | grep "update-dashboard"

# Trigger manuel du dashboard
gh workflow run update-dashboard.yaml
```

### PR pas créée pour nouvelle version
**Symptôme** : Version upstream plus récente mais pas de PR

**Causes possibles** :
1. ❌ `version.sh` retourne erreur
2. ❌ Pattern de registry incorrect
3. ❌ Timeout lors de l'appel API

**Solution** :
```bash
# Tester localement
cd ansible
./version.sh  # Doit retourner version upstream
./version.sh --registry-pattern  # Doit retourner regex pattern

# Tester la comparaison
./make check-updates ansible

# Vérifier logs upstream-monitor
gh run list --workflow=upstream-monitor.yaml
```

### Build échoue sur PR
**Symptôme** : Build fail uniquement sur PR, pas localement

**Causes possibles** :
1. ❌ Différence environnement (GitHub Actions vs local)
2. ❌ Secrets/variables pas disponibles sur PR fork
3. ❌ Registry authentication (normal sur PR)

**Solution** :
- Sur PR, le build ne DOIT PAS pusher (comportement normal)
- Vérifier que `BUILD_MODE=local` lors des PR
- Logs dans GitHub Actions summary

## 📊 Métriques & Monitoring

### Indicateurs de Santé
- **Build success rate** : Visible dans GitHub Actions
- **Dashboard sync lag** : Comparer registry vs dashboard
- **PR auto-merge rate** : minor updates (devrait être ~80%)
- **Version detection accuracy** : Upstream vs published

### Commandes Utiles
```bash
# Lister tous les workflows runs
gh run list --limit 50

# Voir détails d'un run
gh run view <run-id>

# Télécharger logs
gh run download <run-id>

# Trigger manuel upstream monitor
gh workflow run upstream-monitor.yaml

# Forcer rebuild de tous les containers
gh workflow run auto-build.yaml -f force_rebuild=true

# Mettre à jour dashboard
gh workflow run update-dashboard.yaml
```

## 🔐 Permissions Requises

### GITHUB_TOKEN
- `contents: write` : Commit LAST_REBUILD.md, créer PRs
- `packages: write` : Push vers GHCR
- `pages: write` : Déployer GitHub Pages
- `pull-requests: write` : Gérer PRs (créer, merge, close)

### Secrets
- `DOCKERHUB_USERNAME` : Nom d'utilisateur Docker Hub
- `DOCKERHUB_TOKEN` : Token d'authentification Docker Hub

## 📚 Références

- [GitHub Actions Docs](https://docs.github.com/en/actions)
- [Docker Buildx](https://docs.docker.com/buildx/)
- [Jekyll Documentation](https://jekyllrb.com/docs/)
- [GitHub Pages](https://docs.github.com/en/pages)

---

**Dernière mise à jour** : 26 Octobre 2025  
**Auteur** : Docker Containers Automation System
