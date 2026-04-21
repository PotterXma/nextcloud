<?php
$CONFIG = array (
  'htaccess.RewriteBase' => '/',
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'apps_paths' => 
  array (
    0 => 
    array (
      'path' => '/var/www/html/apps',
      'url' => '/apps',
      'writable' => false,
    ),
    1 => 
    array (
      'path' => '/var/www/html/custom_apps',
      'url' => '/custom_apps',
      'writable' => true,
    ),
  ),
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => 
  array (
    'host' => 'redis',
    'password' => '',
    'port' => 6379,
  ),
  'overwritehost' => 'nextcloud.newegg.org',
  'overwriteprotocol' => 'https',
  'trusted_proxies' => 
  array (
    0 => '172.16.0.0/12',
  ),
  'upgrade.disable-web' => true,
  'passwordsalt' => 'FJj4eWAPiyWYiM1mgVbcdmFiQOkR3L',
  'secret' => 'sWE5rxhUbvpcjOPTc/hKnNMgJYVcGNPLs6zkcSMiY9V0GvvT',
  'trusted_domains' => 
  array (
    0 => 'localhost',
    1 => 'nextcloud.newegg.org',
  ),
  'datadirectory' => '/var/www/html/data',
  'dbtype' => 'mysql',
  'version' => '33.0.2.2',
  'overwrite.cli.url' => 'https://nextcloud.newegg.org',
  'dbname' => 'nextcloud',
  'dbhost' => 'db',
  'dbtableprefix' => 'oc_',
  'mysql.utf8mb4' => true,
  'dbuser' => 'nextcloud',
  'dbpassword' => 'nextcl0ud@newegg@456!',
  'instanceid' => 'ochlfl2uvzyn',
  'installed' => true,
  'forbidden_filename_basenames' => 
  array (
    0 => 'con',
    1 => 'prn',
    2 => 'aux',
    3 => 'nul',
    4 => 'com0',
    5 => 'com1',
    6 => 'com2',
    7 => 'com3',
    8 => 'com4',
    9 => 'com5',
    10 => 'com6',
    11 => 'com7',
    12 => 'com8',
    13 => 'com9',
    14 => 'com¹',
    15 => 'com²',
    16 => 'com³',
    17 => 'lpt0',
    18 => 'lpt1',
    19 => 'lpt2',
    20 => 'lpt3',
    21 => 'lpt4',
    22 => 'lpt5',
    23 => 'lpt6',
    24 => 'lpt7',
    25 => 'lpt8',
    26 => 'lpt9',
    27 => 'lpt¹',
    28 => 'lpt²',
    29 => 'lpt³',
  ),
  'forbidden_filename_characters' => 
  array (
    0 => '<',
    1 => '>',
    2 => ':',
    3 => '"',
    4 => '|',
    5 => '?',
    6 => '*',
    7 => '\\',
    8 => '/',
  ),
  'forbidden_filename_extensions' => 
  array (
    0 => ' ',
    1 => '.',
    2 => '.filepart',
    3 => '.part',
  ),
  'mail_smtpmode' => 'smtp',
  'mail_smtphost' => '10.1.37.41',
  'mail_smtpport' => '25',
  'mail_sendmailmode' => 'smtp',
  'mail_smtpstreamoptions' => 
  array (
    'ssl' => 
    array (
      'allow_self_signed' => false,
      'verify_peer' => true,
      'verify_peer_name' => true,
    ),
  ),
  'ldapProviderFactory' => 'OCA\\User_LDAP\\LDAPProviderFactory',
  'maintenance' => false,
  'mail_from_address' => 'nextcloud',
  'mail_domain' => 'newegg.com',
  'mail_smtptimeout' => 30,
  'activity_default_settings' => [
    'email' => [
      'settings' => false,
      'security' => false,
    ],
  ],
);
