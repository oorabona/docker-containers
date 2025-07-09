<?php
require_once __DIR__ . '/../vendor/autoload.php';

// Make sure we admin over SSL
define( 'FORCE_SSL_LOGIN', true );
define( 'FORCE_SSL_ADMIN', true );

/**
 * Use DotEnv to load a mutable environment repository.
 * Means that we can override environment variables in .env file.
 */
$envfile = __DIR__ . '/../.env';
$env = getenv('WP_ENV');

if (!empty($env)) {
    $envfile = $envfile . '.' . $env;
}

if (file_exists($envfile)) {
    $dotenv = Dotenv\Dotenv::createMutable($envfile);
    $dotenv->load();
}

// ** Database settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define( 'DB_NAME', getenv('DB_NAME') );

/** Database username */
define( 'DB_USER', getenv('DB_USER') );

/** Database password */
define( 'DB_PASSWORD', getenv('DB_PASSWORD') );

/** Database hostname */
define( 'DB_HOST', getenv('DB_HOST') );

/** Database charset to use in creating database tables. */
define( 'DB_CHARSET', getenv('DB_CHARSET') );

/** The database collate type. Don't change this if in doubt. */
define( 'DB_COLLATE', getenv('DB_COLLATE') );

/**
 * Authentication Unique Keys and Salts.
 *
 * You can change these at any point in time to invalidate all existing cookies.
 * This will force all users to have to log in again.
 */
$_saltKeys = array(
	'AUTH_KEY',
	'SECURE_AUTH_KEY',
	'LOGGED_IN_KEY',
	'NONCE_KEY',
	'AUTH_SALT',
	'SECURE_AUTH_SALT',
	'LOGGED_IN_SALT',
	'NONCE_SALT',
);

foreach ( $_saltKeys as $_saltKey ) {
	if ( !defined( $_saltKey ) ) {
		define(
			$_saltKey,
			empty( getenv( "WP_$_saltKey" ) ? 'changeme' : getenv( "WP_$_saltKey" ))
		);
	}
}

unset( $_saltKeys, $_saltKey );

/**#@-*/

/**
 * WordPress database table prefix.
 *
 * You can have multiple installations in one database if you give each
 * a unique prefix. Only numbers, letters, and underscores please!
 */

$table_prefix = getenv('TABLE_PREFIX');

$should_update_env_file = false;

// if table prefix is not set, create a random one on 5 characters
if (empty($table_prefix)) {
    $table_prefix = substr(str_shuffle(str_repeat('0123456789abcdefghijklmnopqrstuvwxyz', 5)), 0, 5);
    $should_update_env_file = true;
}

// make sure it ends with an underscore
if (substr($table_prefix, -1) !== '_') {
    $table_prefix .= '_';
    $should_update_env_file = true;
}

// update the env file if needed
if ($should_update_env_file) {
    $dotenv->setEnvironmentVariable('TABLE_PREFIX', $table_prefix);
    $dotenv->save();
}

/**
 * For developers: WordPress debugging mode.
 *
 * Change this to true to enable the display of notices during development.
 * It is strongly recommended that plugin and theme developers use WP_DEBUG
 * in their development environments.
 *
 * For information on other constants that can be used for debugging,
 * visit the documentation.
 *
 * @link https://wordpress.org/support/article/debugging-in-wordpress/
 */
define( 'WP_DEBUG', getenv('WP_ENV') === 'development' );

/* Add any custom values between this line and the "stop editing" line. */

// Get content directory from environment variable
$content_dir = getenv('CONTENT_DIR');
if (empty($content_dir)) {
    $content_dir = 'wp-content';
}

/**
 * WordPress content directory
 */
define('WP_CONTENT_DIR', dirname(__FILE__) . '/'. $content_dir);

/**
 * WordPress plugins directory
 */
define('WP_PLUGIN_DIR', dirname(__FILE__) . '/' . $content_dir . '/plugins');

/**
 * WordPress content directory url
 */
define( 'WP_CONTENT_URL', 'https://' . $_SERVER['HTTP_HOST'] . '/' . $content_dir );

/**
 * This disables live edits of theme and plugin files on the WordPress
 * administration area. It also prevents users from adding, 
 * updating and deleting themes and plugins.
 */
define( 'DISALLOW_FILE_MODS', getenv('WP_ENV') === 'production' );

/**
 * Prevents WordPress core updates, as this is controlled through
 * Composer.
 */
define( 'WP_AUTO_UPDATE_CORE', false );


/* That's all, stop editing! Happy publishing. */

/** Absolute path to the WordPress directory. */
if ( !defined('ABSPATH') )
	define('ABSPATH', dirname(__FILE__) . '/wordpress/');

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';