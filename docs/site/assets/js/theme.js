// Shared theme management for dashboard pages
// Included before page-specific scripts
// API: ThemeManager.currentTheme, ThemeManager.initTheme(), ThemeManager.applyTheme(), ThemeManager.toggleTheme()
(function() {
  var currentTheme = localStorage.getItem('preferredTheme') || 'dark';

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    var icon = document.querySelector('.theme-toggle i');
    if (icon) icon.className = theme === 'dark' ? 'ti ti-moon' : 'ti ti-sun';
  }

  function initTheme() {
    var saved = localStorage.getItem('preferredTheme');
    if (!saved) {
      currentTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
    applyTheme(currentTheme);
  }

  function toggleTheme() {
    currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
    localStorage.setItem('preferredTheme', currentTheme);
    applyTheme(currentTheme);
  }

  // Apply theme immediately to avoid flash
  initTheme();

  // Auto-bind theme toggle button — only on page-layout (blog/static pages).
  // Dashboard and container-detail layouts bind via ThemeManager.toggleTheme()
  // in their own page-specific scripts; binding here too would fire twice per click.
  document.addEventListener('DOMContentLoaded', function() {
    if (!document.body.classList.contains('page-layout')) return;
    var btn = document.querySelector('.theme-toggle');
    if (!btn) return;
    if (btn.dataset.themeAutoBound === '1') return;
    btn.dataset.themeAutoBound = '1';
    btn.addEventListener('click', toggleTheme);
  });

  // Expose as namespace for page-specific scripts
  window.ThemeManager = {
    get currentTheme() { return currentTheme; },
    initTheme: initTheme,
    applyTheme: applyTheme,
    toggleTheme: toggleTheme
  };
})();
