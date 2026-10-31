---
name: candy-wrapper
description: Turn a photo into a vintage Chinese candy-wrapper (糖纸) poster. Use when the user wants a retro wrapper, 复古糖纸, 糖纸风海报, or asks to restyle a photo as a printed candy package. It derives the layout and palette from the photo itself, picks a 3–5 character dessert name, renders either a hand-drawn flat-colour illustration or an offset-print halftone, and finishes with randomised paper tears, fold creases, crumples, stains and misregistration.
---

# 复古糖纸生成器

把任意一张照片做成一张复古糖果包装纸。输出是横版海报（默认 2400×1400，另加不规则纸边）。

设计原则：**糖纸的版式与配色由这张照片推导出来**，不是套模板。同一个 skill 换一张照片，应该长成另一张糖纸。

## 何时使用

- 用户说"做成糖纸 / 复古包装 / 糖纸风 / candy wrapper"
- 用户给一张照片，想要"印出来的"复古食品包装效果
- 用户想要带纸感、套色、褶皱、撕边的平面印刷物

## 使用流程

### 1. 看图，定名字

先打开照片，判断三件事：**主体是什么、主色是什么冷还是暖、细节是密还是疏**。
然后起一个 **3–5 个汉字的糖名**：

- 读起来甜美、像能吃的东西（例：夏日果篮、蜜果一夏、红果满篮、海盐薄荷、冬夜橘光）
- 不要用"图""照""照片"这类词
- 不要与画面无关（拍橘子就别叫"葡萄蜜"）

再写它的**拼音**（大写、按词空格分隔，例：XIA RI GUO LAN）。拼音是版面上的主视觉，别写错。

### 2. 选风格

默认 `--style auto`，按原图自动判断：

| 原图特征 | 自动选用的风格 | 观感 |
| --- | --- | --- |
| 色彩浓烈、主体密集、细节杂乱 | `illust` 四色平涂 + 深色描边 | 手绘 / 丝网上色 |
| 色彩柔和、逆光、层次细腻、单主体 | `halftone` 网点调色 + 红青版错位 | 老照片 / 石版印刷 |

两种都要保留，**不要盲目统一**。用户说"想要手绘的"→ `--style illust`；说"想要老照片那种调子"→ `--style halftone`。

### 3. 运行

```bash
ruby scripts/make.rb \
  --photo "/path/to/photo.jpg" \
  --title "夏日果篮" \
  --pinyin "XIA RI GUO LAN" \
  --out "/path/to/candy-wrapper.jpg"
```

参数：

| 参数 | 说明 |
| --- | --- |
| `--photo` | 源照片（必填） |
| `--title` / `--pinyin` | 糖名与拼音（必填） |
| `--category` | 品类小字，默认「鲜果糖」 |
| `--style` | `auto`（默认）/ `halftone` / `illust` |
| `--layout` | `auto`（默认，三选一随机）/ `center` / `side` / `above` |
| `--seed` | 固定随机种子，同一 seed 可复现同一张 |
| `--palette` | `auto`（默认，从照片取色）/ `warm` / `cool` |
| `--size` | 默认 `2400x1400` |
| `--font-dir` | 自定义字体目录，默认 `fonts/` |
| `--debug` | 打印取色与字体来源，方便调试 |
| `--no-font-fetch` | 禁用在线字体获取，只用本地/系统字体 |

### 4. 交付

告诉用户：风格、版式、糖名。想换一版就**换个 `--seed` 重跑**——纸边、折痕、揉皱、污渍、饰线、编号都会重新随机。

## 三种版式

- `center`：顶部红色拼音条 + 中间照片 + 左右两条樱桃串边带（最对称、最"老牌"）
- `side`：左侧整条深色竖栏（中文竖排 + 拼音竖排），右侧大画面（最像出口罐头标）
- `above`：拼音与中文都在照片上方，下方只留品类与饰线（最留白、最现代）

## 纸感是怎么随机的

每一张都不同，不是同一套压痕：

- **撕边**：四边各自一条低频噪声轮廓，深度 14–34px，带 ±3px 抖动
- **折痕**：1–3 组**平行折**（像纸被叠过再展开），每组 1–4 道，角度、间距、明暗都随机
- **揉皱**：4–14 个正/负高斯团块
- **污渍**：2–6 个褐色晕斑
- **折角**：随机选一个角压暗
- **波浪**：两组不同角度、不同波长的低频起伏
- **纸龄**：整体偏黄/偏青的色偏每次不同
- **纸纤维**、**边缘微暗**、**像素颗粒**

## 生成的糖纸里有什么

- **边带**：贯穿藤蔓 + 单果 + 交替方向的叶（颜色取自照片里的冷色）
- **标题**：拼音用粗几何无衬线（Overt），中文用品名手写体
- **中心画面**：照片按 1320:730 裁切后做分色处理，带套印边框
- **随机饰线**：菱形链 / 波浪 / 圆点列，三选一
- **随机编号**：右下角 01–99
- **不生成厂名** —— 那是模板化，没有意义

## 取色逻辑

照片 → k-means 取 4 色 → 只取**色相方向**，明度和饱和度按版面需要重定：

- 纸色：最亮色与米白混合（少量照片色，保持纸的暖）
- 标题红：最"暖且面积大"的色相，压到中等明度
- 边带深色：最"冷且面积大"的色相，压深、降饱和
- 描边色：最暗色再压深

所以蓝色照片出来的是一张蓝青的糖纸，红色水果照片出来的是红绿糖纸。

## 安装到别的 agent

把整个 `candy-wrapper/` 目录放进该 agent 的 skills 目录即可（Claude Code / Codex / Trae 等同类结构都通用），agent 会读这份 `SKILL.md`。

依赖：

- **Ruby 2.6+**（不用装 gem，所有像素运算都是纯 Ruby）
- **一个 SVG 渲染器**：macOS 自带 `qlmanage`；Linux 用 `rsvg-convert` 或 `inkscape`
- **图片转换**：macOS 用 `sips`；Linux 用 ImageMagick 的 `convert`
- **网络（可选）**：用于运行时获取字体；离线也能跑（回退系统字体）

### 字体（不随包分发）

**这个 skill 不包含任何字体文件**，避免版权风险。字体由安装者自行获取，三级回退：

1. **本地字体**（`fonts/` 目录）：最高优先级。放一个 ttf/woff2，文件名含 `overt`/`anton`/`bebas` 即作为英文主标；含 `westside` 作为英文角字；中文用 `cn.css` + woff2 分片。
2. **运行时在线获取**（默认开启）：英文主标从 Google Fonts 拉 `Anton`（OFL），中文标题从 Google Fonts 拉「马善政毛笔楷书」的**只含标题用字的子集**（几 KB，不内嵌全字库）。字体由使用者的机器请求、不进仓库。
3. **系统字体**：都没有时，英文用 Arial Black/Impact，中文用 Kaiti / Songti / Noto CJK。

预下载英文主标到本地（离线仍有好看的英文字体）：

```bash
ruby scripts/setup_fonts.rb
```

中文字体若想离线也保持手写风，把字体按 `cn.css` 分片格式放进 `fonts/`，或直接用系统楷体。

不想在线拉字体：加 `--no-font-fetch`。

## 注意

- 照片裁成 1320:730，裁切窗口偏右（x0 = 0.20 宽、纵向 55%），主体偏左时先手动裁一下
- 在线获取的中文手写体只覆盖标题用字；冷僻字若 Google 字体缺字会回退系统字体
- 输出约 2400×1400（外加纸边），JPEG 约 500–900KB
- 商用请确认所用字体授权（Google Fonts 的 Anton / 马善政均为 OFL，可商用；自行放置的字体需自行确认）
