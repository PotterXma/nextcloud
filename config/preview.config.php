<?php
/**
 * Nextcloud 预览图生成限制
 *
 * 背景：Nextcloud 默认对所有文件类型（含视频、PDF、Office）生成缩略图，
 * 且无分辨率上限。上传大量文件时 ImageMagick/FFmpeg 会把 CPU 全部打满。
 *
 * 本文件的作用：
 *  1. 把预览最大分辨率限制在 1024x1024（足够列表/预览使用）
 *  2. 只保留轻量级 Provider（图片、文本、Markdown、PDF），
 *     关闭视频、Office 等高消耗 Provider
 *  3. 限制同时并发预览生成数（preview_concurrency_new）
 *
 * 注意：此文件需要挂载到容器内 /var/www/html/config/preview.config.php，
 * 或者在 docker-compose.yaml volumes 下添加：
 *   - ./config/preview.config.php:/var/www/html/config/preview.config.php:ro
 *
 * 若要重新生成已有预览，执行：
 *   docker exec -u www-data nextcloud_app php occ preview:generate-all --batch-size=50
 */
$CONFIG = [
    // ── 分辨率上限 ──────────────────────────────────────────────────────────
    // 生成的缩略图不超过 1024×1024 像素；超大图片不会被完整解码进内存
    'preview_max_x'             => 1024,
    'preview_max_y'             => 1024,
    // 缩放比例不超过原图的 1 倍（禁止放大，省内存）
    'preview_max_scale_factor'  => 1,

    // ── 并发限制 ────────────────────────────────────────────────────────────
    // 同时最多生成 2 个新预览（防止批量上传时把所有 CPU 打满）
    'preview_concurrency_new'   => 2,
    // 已有缓存的预览最多 4 个并发读取
    'preview_concurrency_all'   => 4,

    // ── 只启用轻量级 Provider ───────────────────────────────────────────────
    // 移除了 OC\Preview\Movie（需要 FFmpeg，极其耗 CPU）
    // 移除了 OC\Preview\MSOfficeDoc / MSOffice2003 / MSOffice2007 / OpenDocument
    //   （需要 LibreOffice，冷启动数秒、高内存）
    // 移除了 OC\Preview\Illustrator / Postscript / SVG（ImageMagick 高负载变体）
    'enabledPreviewProviders'   => [
        'OC\Preview\PNG',
        'OC\Preview\JPEG',
        'OC\Preview\GIF',
        'OC\Preview\BMP',
        'OC\Preview\TIFF',
        'OC\Preview\XBitmap',
        'OC\Preview\WebP',
        'OC\Preview\HEIC',
        'OC\Preview\MP3',        // 封面图，轻量
        'OC\Preview\TXT',
        'OC\Preview\MarkDown',
        'OC\Preview\PDF',        // 仅首页截图，需 Ghostscript；若没装可删掉这行
    ],
];
