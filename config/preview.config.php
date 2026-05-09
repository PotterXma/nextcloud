<?php
/**
 * Nextcloud 预览图策略（极致省 CPU）
 *
 * 当前策略：关闭预览生成（enable_previews=false），上传图片时不再跑 ImageMagick/GD，
 * 文件列表显示类型图标，CPU 占用最低。
 *
 * 若需要缩略图：将 enable_previews 改为 true，并视情况恢复 HEIC Provider（iPhone 照片）。
 *
 * 挂载：./config/preview.config.php → /var/www/html/config/preview.config.php
 */
$CONFIG = [
    // 关闭全局预览（省 CPU 最明显；与下方尺寸/Provider 同时存在时以此为准）
    'enable_previews' => false,

    // ── 以下在 enable_previews 为 true 时生效（保留作日后恢复）────────────────
    'preview_max_x'             => 768,
    'preview_max_y'             => 768,
    'preview_max_scale_factor'  => 1,

    'preview_concurrency_new'   => 1,
    'preview_concurrency_all'   => 2,

    'preview_max_filesize_image' => 24,
    'preview_max_memory'        => 96,

    // 未包含 HEIC（iPhone 默认格式解码耗 CPU）；需要时请自行加回 OC\Preview\HEIC
    'enabledPreviewProviders'   => [
        'OC\Preview\PNG',
        'OC\Preview\JPEG',
        'OC\Preview\GIF',
        'OC\Preview\BMP',
        'OC\Preview\TIFF',
        'OC\Preview\XBitmap',
        'OC\Preview\WebP',
        'OC\Preview\MP3',
        'OC\Preview\TXT',
        'OC\Preview\MarkDown',
    ],
];
