#!/usr/bin/env ruby
# 预下载字体到 fonts/ 目录，供离线或缓存使用。
# 本 skill 本身不随包分发任何字体文件，字体由用户在安装时自行获取。
# 英文主标用 Anton（OFL）；中文标题由 make.rb 在运行时按需从 Google Fonts
# 拉取「马善政毛笔楷书」子集，离线时回退到系统中文字体。
require "net/http"
require "uri"
require "fileutils"

FONT_DIR = File.expand_path("../fonts", __dir__)
FileUtils.mkdir_p(FONT_DIR)

def http_get(url, headers = {})
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = url.scheme == "https"
  http.open_timeout = 10
  http.read_timeout = 20
  req = Net::HTTP::Get.new(url)
  headers.each { |k, v| req[k] = v }
  res = http.request(req)
  res.code == "200" ? res.body : nil
rescue => e
  puts "  网络错误：#{e.message}"
  nil
end

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/120 Safari/605"

puts "正在下载 Anton（英文主标，OFL）…"
css = http_get(URI("https://fonts.googleapis.com/css2?family=Anton"), "User-Agent" => UA)
if css && (m = css.match(/src:\s*url\(([^)]+)\)\s*format\(['"]woff2['"]\)/))
  woff_url = URI(m[1].gsub(/^["']|["']$/, ""))
  data = http_get(woff_url, "User-Agent" => UA)
  if data
    File.binwrite(File.join(FONT_DIR, "anton.woff2"), data)
    puts "  ✓ fonts/anton.woff2 (#{data.bytesize} bytes)"
  else
    puts "  ✗ 下载 woff2 失败"
  end
else
  puts "  ✗ 解析 CSS 失败（可能无网络）"
end

puts
puts "完成。make.rb 会优先使用本地 fonts/ 里的字体；"
puts "中文标题运行时按需从 Google Fonts 拉取手写体子集，"
puts "离线环境自动回退到系统中文字体（Kaiti / Songti / Noto CJK）。"
puts
puts "如需指定自己的字体：把 ttf/woff2 放到 fonts/，文件名含 overt/anton/bebas"
puts "（英文主标）或 westside（英文角字）即可；中文字体按 cn.css 分片格式放置。"
