<?php
/**
 * WordPress configuration for Composer-managed deployment.
 * All settings read from environment variables — no secrets in code.
 *
 * Based on cloudrly/wordpress project, simplified for Docker deployment.
 */

/** Composer autoloader */
require_once dirname(__DIR__) . '/vendor/autoload.php';

/** Database settings from environment */
define('DB_NAME', getenv('WORDPRESS_DB_NAME') ?: 'wordpress');
define('DB_USER', getenv('WORDPRESS_DB_USER') ?: 'root');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: '');
define('DB_HOST', getenv('WORDPRESS_DB_HOST') ?: 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

/**
 * Authentication keys and salts.
 * In production, set these as environment variables for session stability.
 * Generate with: wp config shuffle-salts
 */
foreach ([
    'AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
    'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT',
] as $_key) {
    defined($_key) or define($_key, getenv($_key) ?: hash('sha256', $_key . DB_NAME . php_uname()));
}
unset($_key);

/** Database table prefix */
$table_prefix = getenv('WORDPRESS_TABLE_PREFIX') ?: 'wp_';

/**
 * URLs — WP core lives in public/wp/, content in public/wp-content/.
 * This separation is the key benefit of the Composer layout.
 */
$wp_home = getenv('WP_HOME') ?: 'http://localhost';
define('WP_HOME', $wp_home);
define('WP_SITEURL', $wp_home . '/wp');
define('WP_CONTENT_DIR', __DIR__ . '/wp-content');
define('WP_CONTENT_URL', $wp_home . '/wp-content');

/** Security hardening — configurable via environment, locked by default */
define('DISALLOW_FILE_MODS', filter_var(getenv('DISALLOW_FILE_MODS') ?: 'true', FILTER_VALIDATE_BOOLEAN));
define('DISALLOW_FILE_EDIT', filter_var(getenv('DISALLOW_FILE_EDIT') ?: 'true', FILTER_VALIDATE_BOOLEAN));
define('WP_AUTO_UPDATE_CORE', filter_var(getenv('WP_AUTO_UPDATE_CORE') ?: 'false', FILTER_VALIDATE_BOOLEAN));
define('AUTOMATIC_UPDATER_DISABLED', filter_var(getenv('AUTOMATIC_UPDATER_DISABLED') ?: 'true', FILTER_VALIDATE_BOOLEAN));

/** Debug — controlled via environment */
define('WP_DEBUG', filter_var(getenv('WP_DEBUG') ?: 'false', FILTER_VALIDATE_BOOLEAN));

/** Absolute path to the WordPress directory */
if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/wp/');
}

/** Sets up WordPress vars and included files */
require_once ABSPATH . 'wp-settings.php';
