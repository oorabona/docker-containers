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
     pull_count=container.pull_count
     pull_count_formatted=container.pull_count_formatted
     size_amd64=container.size_amd64
     size_arm64=container.size_arm64
  %}
{% endfor %}
</div>

<h2 class="section-title"><i class="ti ti-activity"></i> Recent Activity</h2>

<div class="activity-section glass">
  <div class="activity-list">
    {% if site.data.stats.recent_activity.size > 0 %}
      {% for run in site.data.stats.recent_activity %}
      <a href="{{ run.url }}" target="_blank" class="activity-item activity-link">
        <div class="activity-icon {% if run.conclusion == 'success' %}success{% elsif run.conclusion == 'failure' %}failure{% else %}pending{% endif %}">
          {% if run.conclusion == 'success' %}
            <i class="ti ti-circle-check"></i>
          {% elsif run.conclusion == 'failure' %}
            <i class="ti ti-circle-x"></i>
          {% else %}
            <i class="ti ti-loader"></i>
          {% endif %}
        </div>
        <span class="activity-text">
          <strong>{{ run.name }}</strong>
          <span class="activity-date">{{ run.date }}</span>
        </span>
      </a>
      {% endfor %}
    {% else %}
      <div class="activity-item">
        <div class="activity-icon"><i class="ti ti-robot"></i></div>
        <span><strong>Automated Monitoring</strong> — Upstream versions checked every 6 hours</span>
      </div>
      <div class="activity-item">
        <div class="activity-icon"><i class="ti ti-rocket"></i></div>
        <span><strong>Auto-Build</strong> — Triggered on version updates and code changes</span>
      </div>
    {% endif %}
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
