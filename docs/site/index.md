---
layout: dashboard
title: Container Dashboard
permalink: /
description: Real-time status monitoring for Docker containers with automated upstream version tracking
---

{% include dashboard-stats.html
   total_containers=site.data.stats.total_containers
   up_to_date=site.data.stats.up_to_date
   updates_available=site.data.stats.updates_available
   build_success_rate=site.data.stats.build_success_rate
%}

{% include quick-actions.html %}

<h2 class="section-title"><i class="ti ti-package"></i> Container Status</h2>

<div class="cards-grid">
{% for container in site.data.containers %}
  {% include container-card.html
     name=container.name
     current_version=container.current_version
     latest_version=container.latest_version
     status_color=container.status_color
     status_text=container.status_text
     build_status=container.build_status
     description=container.description
     ghcr_image=container.ghcr_image
     dockerhub_image=container.dockerhub_image
     github_username=container.github_username
     dockerhub_username=container.dockerhub_username
     has_variants=container.has_variants
     variants=container.variants
     versions=container.versions
  %}
{% endfor %}
</div>

<h2 class="section-title"><i class="ti ti-activity"></i> Recent Activity</h2>

<div class="activity-section glass">
  <div class="activity-list">
    <div class="activity-item">
      <div class="activity-icon"><i class="ti ti-robot"></i></div>
      <span><strong>Automated Monitoring</strong> — Upstream versions checked every 6 hours</span>
    </div>
    <div class="activity-item">
      <div class="activity-icon"><i class="ti ti-rocket"></i></div>
      <span><strong>Auto-Build</strong> — Triggered on version updates and code changes</span>
    </div>
    <div class="activity-item">
      <div class="activity-icon"><i class="ti ti-chart-bar"></i></div>
      <span><strong>Dashboard Updates</strong> — Real-time status after successful builds</span>
    </div>
    <div class="activity-item">
      <div class="activity-icon"><i class="ti ti-shield-check"></i></div>
      <span><strong>Branch Protection</strong> — All changes flow through pull requests</span>
    </div>
  </div>
</div>

<h2 class="section-title"><i class="ti ti-heart-rate-monitor"></i> System Health</h2>

<div class="health-section glass">
  <div class="health-grid">
    <div class="health-item">
      <span class="health-label">Build Success Rate</span>
      <span class="health-value">{{ site.data.stats.build_success_rate }}%</span>
    </div>
    <div class="health-item">
      <span class="health-label">Containers Up-to-Date</span>
      <span class="health-value">{{ site.data.stats.up_to_date }}/{{ site.data.stats.total_containers }}</span>
    </div>
    <div class="health-item">
      <span class="health-label">Updates Available</span>
      <span class="health-value">{{ site.data.stats.updates_available }}</span>
    </div>
    <div class="health-item">
      <span class="health-label">Last Check</span>
      <span class="health-value">{{ site.data.stats.last_updated }}</span>
    </div>
  </div>
</div>
