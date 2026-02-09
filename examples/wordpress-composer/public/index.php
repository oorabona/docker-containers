<?php
/**
 * Front controller — loads WordPress from the wp/ subdirectory.
 * Based on cloudrly/wordpress project structure.
 */
define('WP_USE_THEMES', true);
require __DIR__ . '/wp/wp-blog-header.php';
