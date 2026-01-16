---
layout: dashboard
title: Container Dashboard
permalink: /
updated: 2025-07-20 20:42 UTC
description: Real-time status monitoring for Docker containers with automated upstream version tracking
---

{% include dashboard-stats.html
   total_containers="9"
   up_to_date="9"
   updates_available="0"
   build_success_rate="100"
%}

{% include quick-actions.html %}

<h2 class="section-title"><i class="ti ti-package"></i> Container Status</h2>

<div class="cards-grid">
{% include container-card.html
   name="ansible"
   current_version="11.8.0"
   latest_version="11.8.0"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="Ansible built from sources with support for external plugins (Galaxy & Python)"
   ghcr_image="ghcr.io/oorabona/ansible:11.8.0"
   dockerhub_image="docker.io/oorabona/ansible:11.8.0"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="debian"
   current_version="trixie"
   latest_version="trixie"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="Debian Base Container - minimal and optimized for production"
   ghcr_image="ghcr.io/oorabona/debian:trixie"
   dockerhub_image="docker.io/oorabona/debian:trixie"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="openresty"
   current_version="1.27.1.2"
   latest_version="1.27.1.2"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="OpenResty - High Performance Web Platform based on Nginx and LuaJIT"
   ghcr_image="ghcr.io/oorabona/openresty:1.27.1.2"
   dockerhub_image="docker.io/oorabona/openresty:1.27.1.2"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="openvpn"
   current_version="v2.6.14"
   latest_version="v2.6.14"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="OpenVPN built from sources with advanced security features"
   ghcr_image="ghcr.io/oorabona/openvpn:v2.6.14"
   dockerhub_image="docker.io/oorabona/openvpn:v2.6.14"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="php"
   current_version="8.4.10-fpm-alpine"
   latest_version="8.4.10-fpm-alpine"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="PHP-FPM Development Container with Alpine base"
   ghcr_image="ghcr.io/oorabona/php:8.4.10-fpm-alpine"
   dockerhub_image="docker.io/oorabona/php:8.4.10-fpm-alpine"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="postgres"
   current_version="17.5-alpine"
   latest_version="17.5-alpine"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="PostgreSQL Database Container with extensions support"
   ghcr_image="ghcr.io/oorabona/postgres:17.5-alpine"
   dockerhub_image="docker.io/oorabona/postgres:17.5-alpine"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="sslh"
   current_version="v2.2.4"
   latest_version="v2.2.4"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="Lightweight SSLH container for protocol multiplexing (SSH, HTTPS, OpenVPN)"
   ghcr_image="ghcr.io/oorabona/sslh:v2.2.4"
   dockerhub_image="docker.io/oorabona/sslh:v2.2.4"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="terraform"
   current_version="1.12.2"
   latest_version="1.12.2"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="Terraform DevOps Container for infrastructure as code"
   ghcr_image="ghcr.io/oorabona/terraform:1.12.2"
   dockerhub_image="docker.io/oorabona/terraform:1.12.2"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
{% include container-card.html
   name="wordpress"
   current_version="6.8.2"
   latest_version="6.8.2"
   status_color="green"
   status_text="Up to Date"
   build_status="success"
   description="WordPress Container optimized for production deployments"
   ghcr_image="ghcr.io/oorabona/wordpress:6.8.2"
   dockerhub_image="docker.io/oorabona/wordpress:6.8.2"
   github_username="oorabona"
   dockerhub_username="oorabona"
%}
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
      <span class="health-value">100%</span>
    </div>
    <div class="health-item">
      <span class="health-label">Containers Up-to-Date</span>
      <span class="health-value">9/9</span>
    </div>
    <div class="health-item">
      <span class="health-label">Updates Available</span>
      <span class="health-value">0</span>
    </div>
    <div class="health-item">
      <span class="health-label">Last Check</span>
      <span class="health-value">2025-07-20 20:43 UTC</span>
    </div>
  </div>
</div>
