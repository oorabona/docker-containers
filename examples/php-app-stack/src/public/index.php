<?php
/**
 * Sample PHP application — demonstrates PHP + PostgreSQL + OpenResty stack.
 *
 * Reads DB config from environment variables and displays connection status
 * along with sample data from the users table.
 */

$db_host = getenv('DB_HOST') ?: 'postgres';
$db_port = getenv('DB_PORT') ?: '5432';
$db_name = getenv('DB_NAME') ?: 'myapp';
$db_user = getenv('DB_USER') ?: 'appuser';
$db_pass = getenv('DB_PASSWORD') ?: '';

$db_status = 'disconnected';
$users = [];
$pg_version = '';
$error = '';

try {
    $dsn = "pgsql:host={$db_host};port={$db_port};dbname={$db_name}";
    $pdo = new PDO($dsn, $db_user, $db_pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $db_status = 'connected';
    $pg_version = $pdo->query('SELECT version()')->fetchColumn();
    $users = $pdo->query('SELECT id, email, name, created_at FROM users ORDER BY id')->fetchAll();
} catch (PDOException $e) {
    $error = $e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>PHP App Stack</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
        .status { padding: 0.5rem 1rem; border-radius: 4px; margin: 1rem 0; }
        .ok { background: #d4edda; color: #155724; }
        .fail { background: #f8d7da; color: #721c24; }
        table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
        th, td { text-align: left; padding: 0.5rem; border-bottom: 1px solid #ddd; }
        th { background: #f8f9fa; }
        code { background: #f1f1f1; padding: 0.1rem 0.3rem; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>PHP App Stack</h1>

    <div class="status <?= $db_status === 'connected' ? 'ok' : 'fail' ?>">
        Database: <strong><?= htmlspecialchars($db_status) ?></strong>
        <?php if ($error): ?>
            — <?= htmlspecialchars($error) ?>
        <?php endif; ?>
    </div>

    <?php if ($pg_version): ?>
        <p><code><?= htmlspecialchars($pg_version) ?></code></p>
    <?php endif; ?>

    <h2>Stack</h2>
    <table>
        <tr><th>Component</th><th>Info</th></tr>
        <tr><td>PHP</td><td><?= PHP_VERSION ?></td></tr>
        <tr><td>PostgreSQL</td><td><?= $pg_version ? 'Connected' : 'N/A' ?></td></tr>
        <tr><td>Server</td><td><?= htmlspecialchars($_SERVER['SERVER_SOFTWARE'] ?? 'PHP-FPM') ?></td></tr>
    </table>

    <?php if ($users): ?>
        <h2>Users</h2>
        <table>
            <tr><th>ID</th><th>Email</th><th>Name</th><th>Created</th></tr>
            <?php foreach ($users as $u): ?>
                <tr>
                    <td><?= (int)$u['id'] ?></td>
                    <td><?= htmlspecialchars($u['email']) ?></td>
                    <td><?= htmlspecialchars($u['name']) ?></td>
                    <td><?= htmlspecialchars($u['created_at']) ?></td>
                </tr>
            <?php endforeach; ?>
        </table>
    <?php endif; ?>
</body>
</html>
