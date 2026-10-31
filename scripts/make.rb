#!/usr/bin/env ruby
# 复古糖纸生成器 —— 照片 → 印刷感糖纸
# 纯 Ruby 像素运算 + 手写 SVG，渲染交给系统里的渲染器。
# 无 gem 依赖，可在 macOS / Linux 运行。

require "base64"
require "fileutils"
require "tmpdir"
require "net/http"
require "uri"

# ---------------------------------------------------------------- 参数
opts = {
  photo: nil, title: nil, pinyin: nil, category: "鲜果糖",
  style: "auto", layout: "auto", seed: nil, palette: "auto",
  size: "2400x1400", out: nil, font_dir: nil, no_font_fetch: false
}
i = 0
while i < ARGV.size
  k = ARGV[i]
  case k
  when "--photo"    then opts[:photo]    = ARGV[i + 1]; i += 2
  when "--title"    then opts[:title]    = ARGV[i + 1]; i += 2
  when "--pinyin"   then opts[:pinyin]   = ARGV[i + 1]; i += 2
  when "--category" then opts[:category] = ARGV[i + 1]; i += 2
  when "--style"    then opts[:style]    = ARGV[i + 1]; i += 2
  when "--layout"   then opts[:layout]   = ARGV[i + 1]; i += 2
  when "--seed"     then opts[:seed]     = ARGV[i + 1].to_i; i += 2
  when "--palette"  then opts[:palette]  = ARGV[i + 1]; i += 2
  when "--size"     then opts[:size]     = ARGV[i + 1]; i += 2
  when "--out"      then opts[:out]      = ARGV[i + 1]; i += 2
  when "--font-dir" then opts[:font_dir] = ARGV[i + 1]; i += 2
  when "--debug"    then opts[:debug]    = true; i += 1
  when "--no-font-fetch" then opts[:no_font_fetch] = true; i += 1
  else
    abort "未知参数 #{k}" unless k.start_with?("-")
    i += 1
  end
end

abort "用法: ruby make.rb --photo X --title 夏日果篮 --pinyin 'XIA RI GUO LAN' --out X" unless opts[:photo] && opts[:title] && opts[:out]

W, H = opts[:size].split("x").map(&:to_i)
srand(opts[:seed] || Random.new_seed % 100000)

# ---------------------------------------------------------------- 外部工具
def which(*names)
  names.find { |n| ENV["PATH"].to_s.split(":").any? { |p| File.executable?(File.join(p, n)) } }
end

SIPS    = which("sips")
CONVERT = which("convert", "magick")
QL      = which("qlmanage")
RSVG    = which("rsvg-convert")
INK     = which("inkscape")

# ---------------------------------------------------------------- 图像读写（BMP）
def bmp_load(path)
  d = File.binread(path)
  off  = d[10, 4].unpack("V")[0]
  w    = d[18, 4].unpack("l<")[0]
  hraw = d[22, 4].unpack("l<")[0]
  bpp  = d[28, 2].unpack("v")[0]
  topdown = hraw < 0
  h = hraw.abs
  bpr = ((w * bpp + 31) / 32) * 4
  bytes = bpp / 8
  px = Array.new(w * h)
  h.times do |y|
    sy = topdown ? y : (h - 1 - y)
    base = off + sy * bpr
    w.times do |x|
      p = base + x * bytes
      px[y * w + x] = [d.getbyte(p + 2), d.getbyte(p + 1), d.getbyte(p)]
    end
  end
  [w, h, px]
end

def bmp_save(path, w, h, px)
  row = ((w * 24 + 31) / 32) * 4
  body = +""
  (h - 1).downto(0).each do |y|
    line = +""
    (0...w).each do |x|
      r, g, b = px[y * w + x]
      line << b.chr << g.chr << r.chr
    end
    line << ("\x00" * (row - w * 3))
    body << line
  end
  hdr = +"BM"
  hdr << [54 + body.bytesize, 0, 0, 54].pack("VvvV")
  hdr << [40, w, h, 1, 24, 0, body.bytesize, 2835, 2835, 0, 0].pack("Vl<l<vvVVl<l<VV")
  File.binwrite(path, hdr + body)
end

# 任意格式 → BMP（借助系统工具）
def to_bmp(src, dst, max_w = 1900)
  if SIPS
    jpg = dst.sub(/\.bmp$/, ".tmp.jpg")
    system("sips -Z #{max_w} '#{src}' --out '#{jpg}' >/dev/null 2>&1")
    system("sips -s format bmp '#{jpg}' --out '#{dst}' >/dev/null 2>&1")
    FileUtils.rm_f(jpg)
  elsif CONVERT
    system("#{CONVERT} '#{src}' -resize #{max_w}x -depth 8 '#{dst}' >/dev/null 2>&1")
  else
    abort "需要 sips（macOS）或 ImageMagick 来读取图片"
  end
  abort "无法读取 #{src}" unless File.exist?(dst)
end

def img_to_jpeg(src, dst, quality = 88)
  if SIPS
    system("sips -s format jpeg -s formatOptions #{quality} '#{src}' --out '#{dst}' >/dev/null 2>&1")
  elsif CONVERT
    system("#{CONVERT} '#{src}' -quality #{quality} '#{dst}' >/dev/null 2>&1")
  end
  abort "写出失败 #{dst}" unless File.exist?(dst)
end

def img_resize(src, dst, w)
  if SIPS
    system("sips -Z #{w} -s format jpeg -s formatOptions 80 '#{src}' --out '#{dst}' >/dev/null 2>&1")
  elsif CONVERT
    system("#{CONVERT} '#{src}' -resize #{w}x -quality 80 '#{dst}' >/dev/null 2>&1")
  end
end

TMP = Dir.mktmpdir("candy-")
at_exit { FileUtils.rm_rf(TMP) rescue nil }

src_bmp = File.join(TMP, "src.bmp")
to_bmp(opts[:photo], src_bmp)
SW, SH, SPX = bmp_load(src_bmp)

# ---------------------------------------------------------------- 1. 裁切到 1320:730
PW = 1320
PH = 730
x0 = (SW * 0.20).round
cw = SW - x0
ch = (cw * PH / PW.to_f).round
y0 = ((SH - ch) * 0.55).round
y0 = 0 if y0.negative?

panel = Array.new(PW * PH)
PH.times do |y|
  PW.times do |x|
    sx = (x0 + x * cw / PW.to_f).round.clamp(0, SW - 1)
    sy = (y0 + y * ch / PH.to_f).round.clamp(0, SH - 1)
    panel[y * PW + x] = SPX[sy * SW + sx]
  end
end

# ---------------------------------------------------------------- 2. 取色（k-means）
def kmeans(px, k, iter = 8)
  rnd = Random.new(42)
  cents = Array.new(k) { px[rnd.rand(px.size)] }
  k.times do
    groups = Array.new(k) { [] }
    px.each do |c|
      best = 0; bd = Float::INFINITY
      cents.each_with_index do |m, j|
        d = (c[0] - m[0])**2 + (c[1] - m[1])**2 + (c[2] - m[2])**2
        if d < bd then bd = d; best = j end
      end
      groups[best] << c
    end
    cents = groups.map do |g|
      next nil if g.empty?
      [g.sum { |c| c[0] } / g.size, g.sum { |c| c[1] } / g.size, g.sum { |c| c[2] } / g.size]
    end.compact
  end
  cents
end

sample = Array.new(220) do
  x = rand(PW); y = rand(PH)
  panel[y * PW + x]
end
cents = kmeans(sample, 4)

# ---------- 设计色：从照片取的色只提供"色相方向"，明度/饱和度由版式需要决定 ----------
def lum_of(c)  0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] end
def sat_of(c)
  mx = c.max.to_f; mn = c.min.to_f
  mx.zero? ? 0.0 : (mx - mn) / mx
end
def hue_of(c)
  r, g, b = c[0].to_f, c[1].to_f, c[2].to_f
  mx = [r, g, b].max; mn = [r, g, b].min
  return 0.0 if mx == mn
  d = mx - mn
  (mx == r ? (60 * ((g - b) / d)) % 360 : mx == g ? 60 * ((b - r) / d) + 120 : 60 * ((r - g) / d) + 240)
end
def tint(c, l_target, s_floor = 0.45)
  r, g, b = c[0].to_f / 255, c[1].to_f / 255, c[2].to_f / 255
  mx = [r, g, b].max; mn = [r, g, b].min; l = (mx + mn) / 2
  if mx == mn
    h = 0.0; s = 0.0
  else
    d = mx - mn
    s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    h = (mx == r ? ((g - b) / d) % 6 : mx == g ? (b - r) / d + 2 : (r - g) / d + 4) * 60
  end
  s = [s, s_floor].max
  l = l_target
  c2 = (1 - (2 * l - 1).abs) * s
  x = l - c2 / 2
  m = h / 60.0
  seg = m.floor % 6
  f = m - m.floor
  case seg
  when 0 then [x + c2, x + c2 * f, x]
  when 1 then [x + c2 * (1 - f), x + c2, x]
  when 2 then [x, x + c2, x + c2 * f]
  when 3 then [x, x + c2 * (1 - f), x + c2]
  when 4 then [x + c2 * f, x, x + c2]
  else [x + c2, x, x + c2 * (1 - f)]
  end.map { |v| (v * 255).clamp(0, 255).round }
end

counts = Array.new(cents.size, 0)
sample.each do |c|
  idx = cents.each_index.min_by { |j| (c[0] - cents[j][0])**2 + (c[1] - cents[j][1])**2 + (c[2] - cents[j][2])**2 }
  counts[idx] += 1
end
# 取"面积大且够饱和"的那个色相方向，避免被小面积杂色带跑
score = ->(j) { counts[j] * (sat_of(cents[j]) + 0.25) }

sorted = cents.each_index.sort_by { |j| lum_of(cents[j]) }
light = cents[sorted.last]
warm_i = cents.each_index.select { |j| h = hue_of(cents[j]); h < 55 || h > 315 }.max_by(&score)
cool_i = cents.each_index.select { |j| h = hue_of(cents[j]); h > 60 && h < 270 }.max_by(&score)
raw_warm = warm_i ? cents[warm_i] : nil
raw_cool = cool_i ? cents[cool_i] : nil

paper  = light.zip([252, 244, 224]).map { |a, b| (a * 0.18 + b * 0.82).round }
accent = raw_warm && sat_of(raw_warm) > 0.25 ? tint(raw_warm, 0.63, 0.55) : [226, 160, 54]
red    = raw_warm && sat_of(raw_warm) > 0.25 ? tint(raw_warm, 0.42, 0.62) : [168, 56, 40]
green  = raw_cool && sat_of(raw_cool) > 0.18 ? tint(raw_cool, rand(0.29..0.35), rand(0.30..0.40)) : [44, 106, 72]
deep   = tint(cents[sorted.first], 0.20, 0.35)

case opts[:palette]
when "warm" then paper = [250, 240, 216]; accent = [226, 158, 62]; red = [172, 58, 40]
when "cool" then paper = [244, 242, 232]; accent = [96, 148, 140]; red = [52, 104, 118]
end

PAPER, ACCENT, RED, GREEN, DEEP = paper, accent, red, green, deep
if opts[:debug]
  puts "centroids: #{cents.map { |c| c.map { |v| v.round }.inspect }.join(' ')}"
  puts "design: paper=#{PAPER} accent=#{ACCENT} red=#{RED} green=#{GREEN} deep=#{DEEP}"
end

# SVG 里用十六进制色值（数组直接插值会变成 "[252, 244, 224]" 导致填充失效）
def css_rgb(c) format("#%02x%02x%02x", *c.map { |v| v.to_i.clamp(0, 255) }) end

PAL = [PAPER, ACCENT, RED, DEEP]
HEX = {
  paper: css_rgb(PAPER), accent: css_rgb(ACCENT), red: css_rgb(RED),
  deep: css_rgb(DEEP), green: css_rgb(GREEN),
  line: css_rgb(DEEP.map { |v| (v * 0.8).round })
}

# ---------------------------------------------------------------- 3. 主图处理
def box_blur(px, w, h, rad)
  tmp = Array.new(px.size)
  (0...h).each do |y|
    (0...w).each do |x|
      rs = gs = bs = n = 0
      ([x - rad, 0].max..[x + rad, w - 1].min).each do |xx|
        c = px[y * w + xx]; rs += c[0]; gs += c[1]; bs += c[2]; n += 1
      end
      tmp[y * w + x] = [rs / n, gs / n, bs / n]
    end
  end
  out = Array.new(px.size)
  (0...h).each do |y|
    (0...w).each do |x|
      rs = gs = bs = n = 0
      ([y - rad, 0].max..[y + rad, h - 1].min).each do |yy|
        c = tmp[yy * w + x]; rs += c[0]; gs += c[1]; bs += c[2]; n += 1
      end
      out[y * w + x] = [rs / n, gs / n, bs / n]
    end
  end
  out
end

def expose(px)
  px.map do |c|
    c.map do |v|
      v = 255.0 * (v / 255.0)**1.10
      v = 186 + (v - 186) * 0.40 if v > 186
      v.clamp(0, 255).round
    end
  end
end

# --- A. 网点调色（老印刷）
def halftone(px, pal)
  px = expose(px)
  5.times { px = box_blur(px, PW, PH, 1) }
  bayer = [[0,32,8,40,2,34,10,42],[48,16,56,24,50,18,58,26],[12,44,4,36,14,46,6,38],
           [60,28,52,20,62,30,54,22],[3,35,11,43,1,33,9,41],[51,19,59,27,49,17,57,25],
           [15,47,7,39,13,45,5,37],[63,31,55,23,61,29,53,21]]
  out = Array.new(px.size)
  px.each_with_index do |c, i|
    r, g, b = c
    mx = [r, g, b].max.to_f; mn = [r, g, b].min.to_f
    sat = mx.zero? ? 0 : (mx - mn) / mx
    lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    hue = if mx == mn then 0.0
          elsif mx == r then (60.0 * ((g - b) / (mx - mn))) % 360
          elsif mx == g then 60.0 * ((b - r) / (mx - mn)) + 120
          else 60.0 * ((r - g) / (mx - mn)) + 240
          end
    ramp = if sat < 0.16 then [PAL[0], ACCENT, DEEP]
           elsif hue >= 25 && hue < 78 then [PAL[0], ACCENT, RED]
           elsif hue >= 78 && hue < 280 then [PAL[0], GREEN, DEEP]
           else [PAL[0], ACCENT, RED, DEEP]
           end
    t = 1.0 - lum
    t += (bayer[(i / PW) % 8][(i % PW) % 8] / 64.0 - 0.5) * 0.22
    t = t.clamp(0, 0.999)
    out[i] = ramp[(t * ramp.size).floor]
  end
  # 红版 / 青版错位：让边缘出现老印刷的彩色毛边
  shifted = Array.new(out.size)
  (0...PH).each do |y|
    (0...PW).each do |x|
      j = y * PW + x
      c = out[j]
      rx = [x + 2, PW - 1].min
      bx = [x - 2, 0].max
      shifted[j] = [out[y * PW + rx][0], c[1], out[y * PW + bx][2]]
    end
  end
  # 局部随机套印错位
  off = Array.new(shifted.size)
  (0...PH).each do |y|
    (0...PW).each do |x|
      j = y * PW + x
      sx = x; sy = y
      if rand < 0.028
        sx = (x - 2).clamp(0, PW - 1); sy = (y - 1).clamp(0, PH - 1)
      end
      off[j] = shifted[sy * PW + sx]
    end
  end
  off
end

# --- B. 四色平涂 + 描边（手绘）
def illust(px, pal)
  sm = expose(px)
  2.times { sm = box_blur(sm, PW, PH, 4) }

  q = Array.new(sm.size) do |i|
    r, g, b = sm[i]
    mx = [r, g, b].max.to_f; mn = [r, g, b].min.to_f
    lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    sat = mx.zero? ? 0.0 : (mx - mn) / mx
    hue = if mx == mn then 0.0
          elsif mx == r then (60.0 * ((g - b) / (mx - mn))) % 360
          elsif mx == g then 60.0 * ((b - r) / (mx - mn)) + 120
          else 60.0 * ((r - g) / (mx - mn)) + 240
          end
    if lum > 0.72 && sat < 0.35 then 0
    elsif sat > 0.22 && hue >= 25 && hue < 75 then 1
    elsif sat > 0.18 && hue >= 75 && hue < 200 then 3
    else 2
    end
  end

  2.times do
    out = Array.new(q.size)
    (0...PH).each do |y|
      (0...PW).each do |x|
        cnt = Hash.new(0)
        ([y - 2, 0].max..[y + 2, PH - 1].min).each do |yy|
          ([x - 2, 0].max..[x + 2, PW - 1].min).each do |xx|
            cnt[q[yy * PW + xx]] += 1
          end
        end
        out[y * PW + x] = cnt.max_by { |_k, v| v }[0]
      end
    end
    q = out
  end

  # 去掉小色斑
  min_area = (PW * PH / 1500).to_i
  size = PW * PH
  labels = Array.new(size, -1)
  areas = []; neighs = []
  (0...size).each do |s|
    next if labels[s] != -1
    col = q[s]; lid = areas.size; labels[s] = lid
    stack = [s]; area = 0; nb = Hash.new(0)
    while (k = stack.pop)
      area += 1
      x = k % PW; y = k / PW
      nb[q[k - 1]] += 1 if x > 0 && q[k - 1] != col
      nb[q[k + 1]] += 1 if x + 1 < PW && q[k + 1] != col
      nb[q[k - PW]] += 1 if y > 0 && q[k - PW] != col
      nb[q[k + PW]] += 1 if y + 1 < PH && q[k + PW] != col
      [[-1, 0], [1, 0], [0, -1], [0, 1]].each do |dx, dy|
        xx = x + dx; yy = y + dy
        next if xx < 0 || xx >= PW || yy < 0 || yy >= PH
        j = yy * PW + xx
        next unless q[j] == col && labels[j] == -1
        labels[j] = lid; stack.push(j)
      end
    end
    areas << area; neighs << nb
  end
  labels.each_index do |j|
    lid = labels[j]
    next unless areas[lid] < min_area
    nb = neighs[lid]
    q[j] = nb.max_by { |_k, v| v }[0] unless nb.empty?
  end

  edge = Array.new(PW * PH, false)
  (0...(PH - 1)).each do |y|
    (0...(PW - 1)).each do |x|
      j = y * PW + x
      edge[j] = true if q[j] != q[j + 1] || q[j] != q[j + PW]
    end
  end
  wide = Array.new(edge.size, false)
  edge.each_with_index do |f, j|
    next unless f
    x = j % PW; y = j / PW
    wide[j] = true
    wide[j + 1] = true if x + 1 < PW
    wide[j + 2] = true if x + 2 < PW
    wide[j + PW] = true if y + 1 < PH
    wide[j + 2 * PW] = true if y + 2 < PH
  end

  pal4 = [PAL[0], ACCENT, RED, GREEN]
  line_col = DEEP.map { |v| (v * 0.8).round }
  wide.each_index.map { |j| wide[j] ? line_col : pal4[q[j]] }
end

# 自动判断：细节多、颜色浓 → 平涂；柔和逆光 → 网点
def auto_style(px)
  lum_sd = begin
    vals = px.map { |c| 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] }
    m = vals.sum / vals.size
    Math.sqrt(vals.sum { |v| (v - m)**2 } / vals.size)
  end
  # 相邻差分的平均强度（细节密度）
  diff = 0.0
  step = 5
  (0...(PH - step)).step(step) do |y|
    (0...(PW - step)).step(step) do |x|
      a = px[y * PW + x]; b = px[y * PW + x + step]
      diff += (a[0] - b[0]).abs + (a[1] - b[1]).abs + (a[2] - b[2]).abs
    end
  end
  samples = ((PH - step) / step.to_f * (PW - step) / step.to_f)
  diff /= [samples, 1].max
  # 高对比 + 高细节 → illust；否则 halftone
  (lum_sd > 52 && diff > 42) ? :illust : :halftone
end

STYLE = opts[:style] == "auto" ? auto_style(panel) : opts[:style].to_sym
treated = STYLE == :illust ? illust(panel, PAL) : halftone(panel, PAL)

panel_jpg = File.join(TMP, "panel.jpg")
bmp_save(File.join(TMP, "panel.bmp"), PW, PH, treated)
img_to_jpeg(File.join(TMP, "panel.bmp"), panel_jpg, 78)
# 糖纸里放 1000px 足够，大了会让渲染器卡死
small_jpg = File.join(TMP, "panel_small.jpg")
if img_resize(panel_jpg, small_jpg, 1000) && File.exist?(small_jpg)
  panel_jpg = small_jpg
end

# ---------------------------------------------------------------- 4. SVG 拼版
font_dir = opts[:font_dir] || File.expand_path("../fonts", __dir__)
FileUtils.mkdir_p(font_dir)

# --- 工具：从 Google Fonts 拉取指定文字的子集 woff2（按用户本机网络获取，不随包分发）---
def http_get(url, headers = {})
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = url.scheme == "https"
  http.open_timeout = 8
  http.read_timeout = 12
  req = Net::HTTP::Get.new(url)
  headers.each { |k, v| req[k] = v }
  res = http.request(req)
  res.code == "200" ? res.body : nil
rescue
  nil
end

def gf_subset(family, text)
  return nil if text.nil? || text.strip.empty?
  params = URI.encode_www_form(family: family, text: text, display: "swap")
  url = URI("https://fonts.googleapis.com/css2?#{params}")
  ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/120 Safari/605"
  css = http_get(url, "User-Agent" => ua)
  return nil unless css
  m = css.match(/src:\s*url\(([^)]+)\)\s*format\(['"]woff2['"]\)/)
  return nil unless m
  woff_url = URI(m[1].gsub(/^["']|["']$/, ""))
  data = http_get(woff_url, "User-Agent" => ua)
  return nil unless data
  Base64.strict_encode64(data)
end

FONT_CSS = +""

# ---------- 英文主标（粗几何无衬线）：本地优先，否则在线拉 Anton ----------
en_font = nil
%w(overt anton bebas).each do |kw|
  path = Dir.glob(File.join(font_dir, "*#{kw}*")).find { |p| p =~ /\.(ttf|otf|woff2?)$/i }
  next unless path
  ext = File.extname(path).downcase.delete(".")
  fmt = ext == "woff2" ? "woff2" : ext == "woff" ? "woff" : "truetype"
  mime = ext == "woff2" ? "font/woff2" : ext == "woff" ? "font/woff" : "font/truetype"
  b = Base64.strict_encode64(File.binread(path))
  FONT_CSS << %(@font-face{font-family:'EN';src:url(data:#{mime};base64,#{b}) format('#{fmt}');})
  en_font = "EN"
  break
end
if en_font.nil? && !opts[:no_font_fetch]
  py = opts[:pinyin].to_s
  text = py.empty? ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" : py
  b = gf_subset("Anton", text)
  if b
    FONT_CSS << %(@font-face{font-family:'EN';src:url(data:font/woff2;base64,#{b}) format('woff2');})
    en_font = "EN"
  end
end
EN = en_font ? "EN,'Helvetica Neue',sans-serif" : "'Arial Black',Impact,sans-serif"

# ---------- 英文角字（木刻/装饰）：只看本地 ----------
en2_font = nil
path = Dir.glob(File.join(font_dir, "*westside*")).find { |p| p =~ /\.(ttf|otf|woff2?)$/i }
if path
  ext = File.extname(path).downcase.delete(".")
  fmt = ext == "woff2" ? "woff2" : ext == "woff" ? "woff" : "truetype"
  mime = ext == "woff2" ? "font/woff2" : ext == "woff" ? "font/woff" : "font/truetype"
  b = Base64.strict_encode64(File.binread(path))
  FONT_CSS << %(@font-face{font-family:'EN2';src:url(data:#{mime};base64,#{b}) format('#{fmt}');})
  en2_font = "EN2"
end
EN2 = en2_font ? "EN2" : "'Arial Narrow',sans-serif"

# ---------- 中文标题：本地 cn.css 分片 > 在线马善政手写子集 > 系统字体 ----------
cn_font = nil
cn_text = opts[:title].to_s + opts[:category].to_s
css_file = File.join(font_dir, "cn.css")
if File.exist?(css_file)
  css = File.read(css_file)
  css.scan(/url\('([^']+)'\);unicode-range:([^;]+);/).each do |file, range|
    hit = cn_text.chars.any? do |ch|
      cp = ch.ord
      range.split(",").any? do |part|
        part = part.strip.sub(/^U\+/, "")
        a, b2 = part.split("-")
        lo = a.to_i(16); hi = (b2 || a).to_i(16)
        cp >= lo && cp <= hi
      end
    end
    src = File.join(font_dir, file)
    next unless hit && File.exist?(src)
    FileUtils.cp(src, File.join(TMP, File.basename(src)))
    FONT_CSS << %(@font-face{font-family:'CN';src:url('#{File.basename(src)}') format('woff2');unicode-range:#{range};})
    cn_font = "CN"
  end
end
if cn_font.nil? && !opts[:no_font_fetch]
  b = gf_subset("Ma Shan Zheng", cn_text)
  if b
    FONT_CSS << %(@font-face{font-family:'CN';src:url(data:font/woff2;base64,#{b}) format('woff2');})
    cn_font = "CN"
  end
end
CN = cn_font ? "CN,'Kaiti SC','STKaiti','Noto Serif CJK SC',serif" : "'Kaiti SC','STKaiti','Songti SC','Noto Serif CJK SC',serif"

if opts[:debug]
  puts "fonts: EN=#{en_font || 'system'} EN2=#{en2_font || 'system'} CN=#{cn_font || 'system'}"
end

img_b64 = Base64.strict_encode64(File.binread(panel_jpg))
sq = QL ? 2400 : nil           # qlmanage 只能出方形缩略图
pad = sq ? 500 : 0
num = format("%02d", rand(1..99))
LAYOUT = opts[:layout] == "auto" ? %w(center side above).sample : opts[:layout]

def esc(s) s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;") end

def cherry_strip(x0, y1, y2, w = 260)
  cx = x0 + w / 2
  s = +%(<g><rect x="#{x0}" y="#{y1}" width="#{w}" height="#{y2 - y1}" fill="#{HEX[:green]}"/>)
  s << %(<rect x="#{x0 + 12}" y="#{y1 + 12}" width="#{w - 24}" height="#{y2 - y1 - 24}" fill="none" stroke="#{HEX[:paper]}" stroke-width="2" opacity="0.5"/>)
  s << %(<line x1="#{cx}" y1="#{y1 + 56}" x2="#{cx}" y2="#{y2 - 44}" stroke="#{HEX[:paper]}" stroke-width="3" opacity="0.5"/>)
  cy = y1 + 86; k = 0
  while cy < y2 - 40
    dir = k.even? ? -1 : 1
    s << %(<line x1="#{cx}" y1="#{cy - 50}" x2="#{cx}" y2="#{cy - 24}" stroke="#{HEX[:paper]}" stroke-width="3" stroke-linecap="round"/>)
    s << %(<path d="M #{cx} #{cy - 50} Q #{cx + dir * 36} #{cy - 84} #{cx + dir * 54} #{cy - 58} Q #{cx + dir * 26} #{cy - 40} #{cx} #{cy - 50} Z" fill="#{HEX[:paper]}" opacity="0.92"/>)
    s << %(<circle cx="#{cx}" cy="#{cy}" r="22" fill="#{HEX[:red]}"/>)
    s << %(<circle cx="#{cx - 7}" cy="#{cy - 8}" r="5.5" fill="#{HEX[:paper]}" opacity="0.9"/>)
    cy += 124; k += 1
  end
  s << %(</g>)
end

def ornament(y, x1, x2, kind, color)
  s = +%(<g>)
  case kind
  when 0
    x = x1
    while x + 11 <= x2
      s << %(<path d="M #{x} #{y - 11} L #{x + 11} #{y} L #{x} #{y + 11} L #{x - 11} #{y} Z" fill="none" stroke="#{color}" stroke-width="2.5" opacity="0.8"/>)
      x += 78
    end
  when 1
    d = +"M #{x1} #{y}"; x = x1
    while x + 64 <= x2
      d << " Q #{x + 32} #{y - 20} #{x + 64} #{y}"
      x += 64
    end
    s << %(<path d="#{d}" fill="none" stroke="#{color}" stroke-width="4" opacity="0.75"/>)
  else
    x = x1
    while x <= x2
      s << %(<circle cx="#{x}" cy="#{y}" r="6.5" fill="#{color}" opacity="0.7"/>)
      x += 72
    end
  end
  s << %(</g>)
end

def cn_line(cx, base, size, ls, text, color)
  chars = text.chars
  total = chars.size * size + (chars.size - 1) * ls
  x = cx - total / 2.0
  s = +%(<g>)
  chars.each do |ch|
    s << %(<text x="#{(x + size / 2.0).round(1)}" y="#{base}" font-family="#{CN}" font-size="#{size}" fill="#{color}" text-anchor="middle">#{esc(ch)}</text>)
    x += size + ls
  end
  s << %(</g>)
end

def cn_col(xc, y0, size, step, text, color)
  s = +%(<g>)
  text.chars.each_with_index do |ch, k|
    s << %(<text x="#{xc}" y="#{y0 + k * step}" font-family="#{CN}" font-size="#{size}" fill="#{color}" text-anchor="middle">#{esc(ch)}</text>)
  end
  s << %(</g>)
end

def pinyin_col(xc, y0, size, step, text, color, max_y = nil)
  words = text.split(" ")
  if max_y
    chars = [words.sum { |w| w.size }, 1].max
    gaps = 28 * (words.size - 1)
    fit = ([max_y - y0, 40].max - gaps) / chars.to_f
    size = [size, fit * 0.70].min
    step = [step, fit].min
  end
  s = +%(<g>)
  y = y0
  words.each do |word|
    word.chars.each do |ch|
      s << %(<text x="#{xc}" y="#{y}" font-family="#{EN}" font-size="#{size.round}" fill="#{color}" text-anchor="middle">#{esc(ch)}</text>)
      y += step
    end
    y += 28
  end
  s << %(</g>)
end

svg = +%(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="#{sq || W}" height="#{sq || H}" viewBox="0 0 #{sq || W} #{sq || H}">)
svg << %(<defs><style type="text/css">#{FONT_CSS}</style></defs>)
svg << %(<rect width="#{sq || W}" height="#{sq || H}" fill="#{HEX[:paper]}"/>)
svg << %(<g transform="translate(0,#{pad})">)

TITLE = esc(opts[:title])
PY = esc(opts[:pinyin].to_s.upcase)
CAT = esc(opts[:category])

case LAYOUT
when "center"
  svg << cherry_strip(70, 250, 1290)
  svg << cherry_strip(2070, 250, 1290)
  svg << %(<rect x="330" y="70" width="1740" height="180" fill="#{HEX[:red]}"/>)
  svg << %(<line x1="354" y1="88" x2="2046" y2="88" stroke="#{HEX[:paper]}" stroke-width="2" opacity="0.8"/>)
  svg << %(<line x1="354" y1="232" x2="2046" y2="232" stroke="#{HEX[:paper]}" stroke-width="2" opacity="0.8"/>)
  svg << %(<text x="1200" y="172" font-family="#{EN}" font-size="92" letter-spacing="4" fill="#{HEX[:paper]}" text-anchor="middle">#{PY}</text>)
  svg << %(<rect x="496" y="266" width="1408" height="800" fill="#{HEX[:paper]}"/>)
  svg << %(<image x="520" y="290" width="1360" height="752" xlink:href="data:image/jpeg;base64,#{img_b64}" href="data:image/jpeg;base64,#{img_b64}"/>)
  svg << %(<rect x="520" y="290" width="1360" height="752" fill="none" stroke="#{HEX[:red]}" stroke-width="5"/>)
  svg << cn_line(1200, 1148, 124, 26, TITLE, HEX[:red])
  svg << cn_line(1200, 1222, 50, 14, CAT, HEX[:green])
  svg << %(<text x="1200" y="1266" font-family="#{CN}" font-size="28" letter-spacing="5" fill="#{HEX[:deep]}" text-anchor="middle">· 注 册 商 标 ·</text>)
  svg << ornament(1322, 720, 1680, rand(3), HEX[:red])
  svg << %(<text x="2318" y="1360" font-family="#{EN2}" font-size="30" fill="#{HEX[:red]}" text-anchor="end">#{num}</text>)
  svg << %(<text x="82" y="1360" font-family="#{EN2}" font-size="30" fill="#{HEX[:red]}">CHINA</text>)

when "side"
  svg << %(<rect x="70" y="70" width="430" height="1220" fill="#{HEX[:green]}"/>)
  svg << %(<rect x="84" y="84" width="402" height="1192" fill="none" stroke="#{HEX[:paper]}" stroke-width="2" opacity="0.5"/>)
  svg << cn_col(210, 470, 132, 168, TITLE, HEX[:paper])
  svg << pinyin_col(404, 470, 50, 70, PY, HEX[:paper], 1250)
  svg << %(<rect x="540" y="230" width="1732" height="962" fill="#{HEX[:paper]}"/>)
  svg << %(<image x="560" y="250" width="1692" height="922" xlink:href="data:image/jpeg;base64,#{img_b64}" href="data:image/jpeg;base64,#{img_b64}"/>)
  svg << %(<rect x="560" y="250" width="1692" height="922" fill="none" stroke="#{HEX[:red]}" stroke-width="5"/>)
  svg << cn_line(1406, 1224, 46, 14, CAT, HEX[:green])
  svg << ornament(1290, 1076, 1736, rand(3), HEX[:red])
  svg << %(<text x="2318" y="1360" font-family="#{EN2}" font-size="30" fill="#{HEX[:red]}" text-anchor="end">#{num}</text>)

else # above
  svg << cherry_strip(70, 360, 1290, 220)
  svg << cherry_strip(2110, 360, 1290, 220)
  svg << %(<text x="1200" y="176" font-family="#{EN}" font-size="86" letter-spacing="6" fill="#{HEX[:red]}" text-anchor="middle">#{PY}</text>)
  svg << cn_line(1200, 330, 118, 28, TITLE, HEX[:red])
  svg << %(<line x1="700" y1="368" x2="1700" y2="368" stroke="#{HEX[:green]}" stroke-width="3" opacity="0.65"/>)
  svg << %(<rect x="440" y="378" width="1520" height="850" fill="#{HEX[:paper]}"/>)
  svg << %(<image x="462" y="400" width="1476" height="816" xlink:href="data:image/jpeg;base64,#{img_b64}" href="data:image/jpeg;base64,#{img_b64}"/>)
  svg << %(<rect x="462" y="400" width="1476" height="816" fill="none" stroke="#{HEX[:red]}" stroke-width="5"/>)
  svg << cn_line(1200, 1292, 48, 14, CAT, HEX[:green])
  svg << ornament(1338, 780, 1620, rand(3), HEX[:red])
  svg << %(<text x="2318" y="1360" font-family="#{EN2}" font-size="30" fill="#{HEX[:red]}" text-anchor="end">#{num}</text>)
end

# 纸纤维
90.times do
  svg << %(<rect x="#{rand(W)}" y="#{rand(H)}" width="#{rand(2..6)}" height="#{rand(2..5)}" fill="#C9B795" opacity="#{(rand(20..55) / 100.0).round(2)}"/>)
end
svg << %(</g></svg>)

svg_path = File.join(TMP, "wrapper.svg")
File.write(svg_path, svg)

# ---------------------------------------------------------------- 5. 渲染
png_path = File.join(TMP, "render.png")
if RSVG
  system("#{RSVG} -w #{sq || W} -h #{sq || H} '#{svg_path}' -o '#{png_path}' >/dev/null 2>&1")
elsif QL
  outdir = File.join(TMP, "ql"); FileUtils.mkdir_p(outdir)
  system("qlmanage -t -s #{sq} -o '#{outdir}' '#{svg_path}' >/dev/null 2>&1")
  cand = Dir.glob(File.join(outdir, "*.png")).first
  abort "qlmanage 渲染失败" unless cand
  system("sips -c #{H} #{W} '#{cand}' --out '#{png_path}' >/dev/null 2>&1") if SIPS
  png_path = cand unless SIPS
elsif INK
  system("#{INK} '#{svg_path}' -w #{sq || W} -h #{sq || H} -o '#{png_path}' >/dev/null 2>&1")
else
  abort "没有可用的 SVG 渲染器（需要 qlmanage / rsvg-convert / inkscape）"
end
abort "渲染失败" unless File.exist?(png_path)

bmp = File.join(TMP, "paper.bmp")
if SIPS
  system("sips -s format bmp '#{png_path}' --out '#{bmp}' >/dev/null 2>&1")
elsif CONVERT
  system("#{CONVERT} '#{png_path}' -depth 8 '#{bmp}' >/dev/null 2>&1")
else
  abort "需要 sips 或 ImageMagick 才能做纸感处理"
end

# ---------------------------------------------------------------- 6. 纸感（随机）
rw, rh, rpx = bmp_load(bmp)

PAD_TEAR = rand(34..56)                       # 四周留白，供撕边
ow = rw + PAD_TEAR * 2
oh = rh + PAD_TEAR * 2
outside = [253, 251, 246]
canvas = Array.new(ow * oh, outside)
rh.times do |y|
  rw.times do |x|
    canvas[(y + PAD_TEAR) * ow + (x + PAD_TEAR)] = rpx[y * rw + x]
  end
end

# 撕裂边缘：每条边一条低频噪声轮廓
def tear_profile(len, depth)
  base = rand(0..depth)
  prof = Array.new(len)
  # 3 组正弦叠加 + 抖动
  f1 = rand(0.6..1.8); f2 = rand(2.5..6.0); f3 = rand(7.0..14.0)
  a1 = rand(0.4..1.0); a2 = rand(0.2..0.6); a3 = rand(0.05..0.2)
  ph = [rand(6.28), rand(6.28), rand(6.28)]
  len.times do |i|
    v = base + depth * (a1 * Math.sin(i.to_f / len * 6.28 * f1 + ph[0]) +
                        a2 * Math.sin(i.to_f / len * 6.28 * f2 + ph[1]) +
                        a3 * Math.sin(i.to_f / len * 6.28 * f3 + ph[2]))
    prof[i] = (v + rand(-3.0..3.0)).clamp(0, depth).round
  end
  prof
end

TD = rand(14..34)
tp_top = tear_profile(ow, TD)
tp_bot = tear_profile(ow, TD)
tp_left = tear_profile(oh, TD)
tp_right = tear_profile(oh, TD)

# 折痕：成组的平行折（像纸被叠过再展开），1–3 组、每组 1–4 道
creases = []
rand(1..3).times do
  ang = rand(0..Math::PI)
  nx = Math.cos(ang); ny = Math.sin(ang)
  cx = rand(0..ow); cy = rand(0..oh)
  group = rand(1..4)
  amp = rand(5..13)
  group.times do |g|
    offset = (g - (group - 1) / 2.0) * rand(16..40)
    creases << [nx, ny, cx + nx * offset, cy + ny * offset, amp * rand(0.55..1.0)]
  end
end
# 揉皱团块：随机高斯斑
crumples = Array.new(rand(4..14)) do
  [rand(0..ow), rand(0..oh), rand(70..260), (rand(3..9).to_f * (rand < 0.5 ? 1 : -1))]
end
# 污渍
stains = Array.new(rand(2..6)) do
  [rand(0..ow), rand(0..oh), rand(40..150), rand(0.04..0.13)]
end
# 折角
corner = ["tl", "tr", "bl", "br"].sample
corner_size = rand(80..180)

# 低频波纹
w1 = rand(0.4..1.2); w2 = rand(1.2..2.6)
pa = rand(6.28); pb = rand(6.28)
wamp1 = rand(3..8); wamp2 = rand(2..5)
dir1 = rand(0..Math::PI); dir2 = rand(0..Math::PI)

# 纸龄：每次生成的泛黄/褪色倾向都不同
age = rand(-12..16)
age_r = 1.0 + age * 0.0035
age_g = 1.0 + age * 0.0018
age_b = 1.0 - age * 0.0032

final = Array.new(ow * oh)
is_outside = Array.new(ow * oh, false)
oh.times do |y|
  ow.times do |x|
    # 撕边
    d_top = y; d_bot = oh - 1 - y; d_left = x; d_right = ow - 1 - x
    if d_top < tp_top[x] || d_bot < tp_bot[x] || d_left < tp_left[y] || d_right < tp_right[y]
      final[y * ow + x] = outside
      is_outside[y * ow + x] = true
      next
    end

    r, g, b = canvas[y * ow + x]

    field = 0.0
    # 波纹
    field += wamp1 * Math.sin((x * Math.cos(dir1) + y * Math.sin(dir1)) / ow * 6.28 * w1 + pa)
    field += wamp2 * Math.sin((x * Math.cos(dir2) + y * Math.sin(dir2)) / oh * 6.28 * w2 + pb)

    # 直折痕
    creases.each do |nx, ny, ccx, ccy, amp|
      d = (x - ccx) * nx + (y - ccy) * ny
      field += amp * Math.exp(-(d / 4.0)**2)
      field -= 0.8 * amp * Math.exp(-((d - 7.0) / 5.0)**2)
    end

    # 揉皱
    crumples.each do |sx, sy, rad, amp|
      dx = x - sx; dy = y - sy
      d2 = dx * dx + dy * dy
      field += amp * Math.exp(-d2 / (rad * rad))
    end

    # 折角暗区
    cs = corner_size
    if (corner == "tl" && x < cs && y < cs) || (corner == "tr" && x > ow - cs && y < cs) ||
       (corner == "bl" && x < cs && y > oh - cs) || (corner == "br" && x > ow - cs && y > oh - cs)
      cx0 = (corner == "tl" || corner == "bl") ? x : ow - 1 - x
      cy0 = (corner == "tl" || corner == "tr") ? y : oh - 1 - y
      field -= 7 * Math.exp(-((cx0 + cy0) / cs.to_f)**2 * 3)
    end

    # 边缘微暗
    mn = [d_top, d_bot, d_left, d_right].min
    field -= 8 * Math.exp(-(mn / 26.0))

    # 纸面颗粒
    grain = rand(-3.0..3.0)

    v = field + grain
    v = v.clamp(-30, 30)

    rr = (r + v) * age_r; gg = (g + v * 0.97) * age_g; bb = (b + v * 0.9) * age_b

    # 污渍（褐斑）
    stains.each do |sx, sy, rad, st|
      dx = x - sx; dy = y - sy
      d2 = dx * dx + dy * dy
      k = st * Math.exp(-d2 / (rad * rad))
      next if k < 0.01
      rr = (rr * (1 - k) + 168 * k)
      gg = (gg * (1 - k) + 146 * k)
      bb = (bb * (1 - k) + 104 * k)
    end

    final[y * ow + x] = [rr.clamp(0, 255).round, gg.clamp(0, 255).round, bb.clamp(0, 255).round]
  end
end

# 撕边阴影：纸边与背景色太接近，靠 1px 暗边让毛边看得出来
(1...(oh - 1)).each do |y|
  (1...(ow - 1)).each do |x|
    j = y * ow + x
    next if is_outside[j]
    near = is_outside[j - 1] || is_outside[j + 1] || is_outside[j - ow] || is_outside[j + ow]
    next unless near
    c = final[j]
    final[j] = [c[0] - 16, c[1] - 14, c[2] - 10].map { |v| v.clamp(0, 255) }
  end
end

out_bmp = File.join(TMP, "out.bmp")
bmp_save(out_bmp, ow, oh, final)
img_to_jpeg(out_bmp, opts[:out], 88)

puts "✓ #{opts[:out]}"
puts "  style=#{STYLE} layout=#{LAYOUT} title=#{opts[:title]} palette=#{opts[:palette]}"
puts "  creases=#{creases.size} crumples=#{crumples.size} stains=#{stains.size} corner=#{corner} #{ow}x#{oh}"
