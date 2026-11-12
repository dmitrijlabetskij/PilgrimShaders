# Архитектура рендеринга, алгоритмы и стоимость кадров PilgrimShaders

Документ описывает актуальный пайплайн шейдерпака **PilgrimShaders** (Iris OpenGL 3.3 + переносимое ядро `/lib/*` для Vulkan GLSL 450), используемые алгоритмы для каждого элемента сцены, обращения к памяти и вычислительную сложность.

---

## 1. Общая структура пайплайна и проходы кадра

Пайплайн использует **гибридный Deferred + Forward рендер** с минимальным G-буфером (8 байт/пиксель) и без многопроходных экранных эффектов (без TAA, SSR, Bloom, SSBO и текстурных LUT):

1. **Теневой проход (только Overworld)**: `shadow_solid` → `shadow`.
2. **Непрозрачный и вырезной G-буфер**: `gbuffers_terrain_solid`, `gbuffers_terrain`, `gbuffers_entities`, `gbuffers_block`, `gbuffers_hand` + цветные вспомогательные проходы (`gbuffers_basic`, `gbuffers_line`, `gbuffers_damagedblock`, `gbuffers_spidereyes`, `gbuffers_beaconbeam`, `gbuffers_armor_glint`).
3. **Отключение ванильного неба**: `sky = false`, `sun = false`, `moon = false`, `stars = false`, `clouds = off` в `shaders.properties` + резервное отсечение в `sky_cull_pass.glsl`.
4. **Единый отложенный проход (Deferred)**: `deferred.vsh` / `deferred.fsh` (`deferred_pass.glsl`).
5. **Вода и полупрозрачное стекло**: `gbuffers_water.vsh` / `gbuffers_water.fsh` (`water_pass.glsl`).
6. **Пост-отложенный Forward для полупрозрачности**: `gbuffers_entities_translucent`, `gbuffers_block_translucent`, `gbuffers_textured`, `gbuffers_hand_water`, `gbuffers_weather` (`forward_common.glsl`).
7. **Финальный пост-проход**: `final.vsh` / `final.fsh` (`final_pass.glsl`).

### Формат G-буфера (`8 байт/пиксель`)

| Буфер | Формат | Назначение | Источник |
| --- | --- | --- | --- |
| `colortex0` | `R11F_G11F_B10F` (4 Б) | Линейное альбедо (до `deferred`), затем линейный HDR-свет | [deferred_pass.glsl](shaders/lib/deferred_pass.glsl#L60) |
| `colortex1` | `RGBA8` (4 Б) | `.rg` — октаэдрическая нормаль; `.b` — `skyLight` (8 бит); `.a` — 5 бит `sqrt(blockLight)` + `IGN` дизеринг \| 3 бита `matId` (`0..7`) | [packing.glsl](shaders/lib/packing.glsl#L7-L60) |
| `depthtex0` / `depthtex1` | Depth (4 Б) | Глубина всей сцены / непрозрачной сцены за водой и стеклом | — |
| `shadowtex0` / `shadowtex1` | Depth (только Overworld) | Карта теней (HW PCF) + глубина блокера для адаптивной полутени PCSS (`shadowcolor*` не выделяется) | [shadows.glsl](shaders/lib/shadows.glsl#L10) |

---

## 2. Отрисовка элементов и алгоритмы

### 2.1. Тени (`shadows.glsl`, `shadow_pass.glsl`, `shaders.properties`)
* **Разделение геометрии**: сплошные блоки в `shadow_solid.fsh` используют пустой фрагментный шейдер без `texture()` и `discard` (полный аппаратный Early-Z / Hi-Z). Альфа-тест остаётся только в `shadow.fsh` для листвы, травы и вырезных блоков.
* **Отсечение на уровне настроек**: `shadow.culling = true`, `shadowDistanceRenderMul = 1.0`, `entityShadowDistanceMul = 1.0` (плюс отсечение сущностей и игрока по радиусу 64 блоков в `shadow.fsh` при `MC_RENDER_STAGE_ENTITIES`), `shadowIntervalSize = 4.0`, отключены тени от block-entities и частиц (`shadowBlockEntities = false`, `shadowParticles = false`). Вода (`BLOCK_WATER`) отбрасывается в `shadow.vsh`, чтобы солнце достигало дна без `shadowtex1`.
* **Измерения без солнца**: в `world-1` (Незер) и `world1` (Энд) `shadowtex0` исключён из объявлений фрагментных шейдеров (`deferred_pass.glsl`, `water_pass.glsl`, `forward_common.glsl`), а вершины `shadow.vsh` отбрасываются за пределы clip-space.
* **Радиальное искажение**: `distortShadowClip` делит `clipPos.xy` на `mix(1.0, length(clipPos.xy), SHADOW_DISTORTION)` (`0.78`), концентрируя плотность текселей вблизи игрока.
* **Фильтрация и борьба с артефактами**:
  * Ранний выход при `shadowFade <= 0.001` или `(!isFoliage && NdotL <= 0.0)` и при `skyLight <= 0.02` в пещерах (0 чтений `shadowtex0`).
  * Адаптивный normal-offset bias в мировом пространстве пропорционально размеру искажённого текселя + depth bias (`0.00095 * distortFactor`).
  * **Адаптивная полутень (PCSS)**: поиск расстояния до блокера в `shadowtex1` (`1` центр + `3` пробы с радиусом до `0.28` блока, ранний выход `1.0` на открытом солнце без PCF). У контакта с землёй (`0.055–0.12` блока) работает компактный диск Фогеля (`SHADOW_SAMPLES`: `1..4`), а выше `2.5` блоков от объекта радиус растёт вплоть до `0.32` блока / `8.0` текселя с расширением до 8 выборок HW 2×2 PCF.
  * В `shadow.vsh` колыхание травы и листвы отключено, чтобы тонкие вырезные тени не мерцали при движении вершин.

### 2.2. Непрозрачные блоки, растительность, мобы и рука (`gbuffer_common.glsl`, `waving.glsl`, `packing.glsl`)
* **Вершинная анимация (`calcWavingOffset`)**: чистый ALU на многочастотных `sin/cos`, где пространственные частоты кратны `TAU / 64.0`, а координаты берутся по модулю `64` (`getWorldPosMod64`) — это устраняет швы и потерю точности далеко от спавна.
  * `BLOCK_FOLIAGE_GROUND` (`10002`, трава, цветы, посевы): нижние вершины зафиксированы по `mc_midTexCoord.y`, верхние качаются горизонтально с модулируемым порывом ветра (`0.032 + 0.016 * gust`).
  * `BLOCK_FOLIAGE_CANOPY` (`10003`, листва, лозы): плавное 3D-колыхание. Плоские прилегающие блоки (`glow_lichen`, `moss_carpet`) исключены из волнения в `block.properties`, чтобы не уходить в глубь стены в Z-буфере.
* **Упаковка нормалей и света (`packGbufferData`)**:
  * Нормали (по кубическим граням в world-space) кодируются октаэдрической проекцией в `[0, 254/255]` (`octEncode`) — точное представление осей ±X/±Y/±Z в 8 битах без потерь.
  * `blockLight` сжимается в 5 бит через `sqrt(blockLight)` с дизерингом `IGN` (сохраняет точность на тёмных значениях в пещерах) и упаковывается с 3-битным `matId` в `.a`.
* **Прозрачные скины и сущности**: включён `separateEntityDraws = true` и отключён альфа-блендинг для `colortex1`, чтобы полупрозрачная одежда скинов не портила упакованную нормаль/свет.

### 2.3. Освещение поверхностей (`lighting.glsl`, `deferred_pass.glsl`)
* **Предрасчёт кадра и реконструкция без матриц в FS**: `buildAtmosphere(...)`, `shadowVP = shadowProjection * shadowModelView`, коэффициенты линейной глубины `vDepthCoeff` и интерполируемый мировой луч `vWorldRay` вычисляются в `deferred.vsh`. Во фрагментном шейдере `feetPos = vWorldRay * (1 / (vDepthCoeff.x * depth + vDepthCoeff.y)) + vCameraOffset` (а на небе просто `normalize(vWorldRay)`), без единого `mat4 * vec4` на пиксель.
* **Direct + Sky Ambient + Caves**:
  * Прямой солнечный/лунный свет умножается на `skyLightMask = smoothstep(0.02, 0.28, skyLight)`, полностью исключая засветы граней и предметов мобов в тёмных пещерах от back-face culled теней.
  * Для `MAT_FOLIAGE` добавляется полусферный wrap-свет и просвет листвы (`backScatter = clamp01(dot(-V, -L))^3 * 0.42`).
  * Полусферный sky ambient интерполирует `ambientGroundColor` и `ambientSkyColor` с лёгким отскоком `sunBounce` и минимальным полом пещер (`caveFloor`, усиливается при `nightVision`).
  * Лунный свет `moonLight = (0.042, 0.060, 0.105)` мягко сбалансирован с ночным небом, чтобы ночь оставалась тёмной и без жёсткого теневого контраста.
* **Факелы, ручной свет и блеск**:
  * `evalBlockLight`: приглушённый тёпло-жёлтый градиент без пересвета в белый под `AgX`.
  * `evalDynamicHandlight`: квадратичное затухание `1 / (1 + 0.16 * d^2)` с радиусом `14 * handLightLevel`.
  * `MAT_SPECULAR` (и верхние мокрые грани во время дождя): блик Блинна-Фонга + Френель Шлика по небу.
  * `MAT_EMISSIVE`: самосвечение ярких текселей (`smoothstep(0.06, 0.32, luma) * 2.40`).

### 2.4. Небо, звёзды, светила, облака и туман (`atmosphere.glsl`, `noise.glsl`)
* **Ранний выход неба**: в `deferred.fsh` пиксели с `depth >= 0.999999` пропускают чтение `colortex0`, `colortex1` и `shadowtex0`.
* **Небо (`evalSkyGradient`)**: аналитический экспоненциальный градиент зенит–горизонт, ореол Ми вокруг солнца на последовательных квадратах (`sc2 -> sc6 -> sc36`, без `pow`), холодный ореол луны.
* **Звёзды, солнце и луна (`evalProceduralStars`, `evalOverworldSky`)**: звёзды — 3D-сферическая сетка `hash31` с мерцанием и цветовой температурой; солнце — сглаженный диск + корона; луна — диск с процедурными кратерами на `valueNoise2D`.
* **Псевдо-объёмные облака (`cloudShapeSlice`, `cloudShapeShadow`, `evalProceduralClouds`)**:
  * Сферически-купольная проекция `1 / (viewDir.y + 0.09)` предотвращает растяжение у горизонта.
  * 5-слойный срез облачного слоя (`STEPS = 5`, ранний выход при `transmittance < 0.04`) на базе `cloudShapeSlice`: плоское прохладно-затенённое основание, округлые светлые купола наверху, параллакс объёма и серебристая кайма Ми со стороны солнца.
* **Туман (`applyOverworldFog`, `applyOverworldMediumAndFog`)**: дистанционный экспоненциальный туман + низинная дымка (`exp(-max(y - 62, 0) * 0.032)`) + плавное слияние на границе `far`. Под водой цвет тумана привязан к `ambientSkyColor` и `directLightColor`.

### 2.5. Вода и стекло (`water_pass.glsl`, `water.glsl`)
* **Вершинные волны**: мягкое вертикальное смещение `BLOCK_WATER` на двух волнах (в `calcWavingOffset`, чуть ниже `y = 1.0`, чтобы не вылезать на берег).
* **Без ванильной текстуры**: для `BLOCK_WATER` чтение `gtexture` пропущено; цвет основы берётся из гладкого биомного оттенка `vColor.rgb * 0.84`.
* **Процедурная рябь (`calcWaterNormal`)**: три повёрнутых под разными углами `C2`-непрерывных (квинтических) слоя `valueNoise2DGradAniso` с периодической привязкой к тору `64×64` и аналитическим градиентом (без карт нормалей и сеточных заломов) с затуханием мелкой ряби по дистанции (`detailFade = 1 / (1 + 0.036 * dist)`).
* **Мутность строго по водному пути**: `waterPathDist = viewDist * max(opaqueLinearZ / vWaterLinearZ - 1.0, 0.0)` через `depthtex1` и предрасчитанный `vDepthCoeff` — полностью исключает расстояние в воздухе и не требует обратных матриц 4×4 в `gbuffers_water.fsh`.
* **Освещение, отражения и альфа**: заполняющий цвет `waterFill` зависит от прямого/небесного света, теней и блочного света; отражения — Френель Шлика + облегчённая `evalWaterReflectionSky` (градиент, солнце/луна и 2-октавная `cloudShapeShadow` с 1 шагом затенения) + 2-лепестковый солнечный блик (`h64`, `h512` без `pow`); альфа компенсирована под стандартный `SRC_ALPHA / ONE_MINUS_SRC_ALPHA` блендинг.
* **Стекло, лёд, слайм**: `MAT_SPECULAR` + отражение градиента неба по Френелю.

### 2.6. Пост-отложенные полупрозрачные проходы и пост-обработка (`forward_common.glsl`, `tonemap.glsl`)
* **Forward (`gbuffers_entities_translucent`, `block_translucent`, `textured`, `hand_water`, `weather`)**: атмосфера предрасчитывается в вершинном шейдере (`flat out`); карты теней не сэмплируются (`FORWARD_SHADOWS` отключён). Для частиц (`FORWARD_VERTEX_LIT`) свет считается в вершинном шейдере, а во фрагментном остаются текстура, искры и туман; для дождя (`FORWARD_WEATHER`) используется облегчённый путь без PBR-ветки.
* **Экранные лучи и тонмаппинг (`final_pass.glsl`, `tonemap.glsl`)**: при `GOD_RAYS` вне конуса солнца (и в Незере/Энде, ночью, в дождь) выполняется **1 чтение** (`colortex0`), а внутри конуса солнца — 8 `IGN`-дизеризованных шагов (`depthtex0` в воздухе; `depthtex1` + 5-шаговая 3D-проекция волновых колонн с преломлением Снеллиуса под водой). Далее применяется `AgX Minimal` или `ACES`, `SATURATION`, S-кривая контраста в sRGB и треугольный 8-битный дизеринг `ignCentered / 255.0`.

---

## 3. Оценка обращений к памяти и вычислительной сложности

Оценки приведены **на 1 пиксель** (или **на 1 вершину** для геометрии) с учётом кэширования GPU.

| Стадия / Тип пикселя | Чтения текстур / буферов на пиксель | Записи в память на пиксель | Ориентировочная сложность (ALU / асимптотика) |
| --- | --- | --- | --- |
| **`shadow_solid`** (VS / FS) | **0** текстур | Depth write (`shadowtex0`, Hi-Z) | VS: ~15 ALU/вершина (`distortShadowClip`). FS: `0` (пустой) |
| **`shadow` cutout** (VS / FS) | **1** (`gtexture` в FS) | Depth write (`shadowtex0`) | VS: ~15 ALU/вершина. FS: ~4 ALU (alpha test + `discard`) |
| **`gbuffers_terrain_solid`** (FS) | **1** (`gtexture`) | `colortex0` (4 Б) + `colortex1` (4 Б) + Depth | ~25 ALU (`srgbToLinear`, `octEncode`, `IGN`, битовая упаковка) |
| **`gbuffers_terrain` cutout** (VS + FS) | **1** (`gtexture` в FS) | `colortex0` (4 Б) + `colortex1` (4 Б) + Depth | VS: +18–25 ALU для волнения травы/листвы. FS: ~28 ALU + `discard` |
| **`gbuffers_sky*` / `clouds`** | **0** | **0** (отсечено в VS) | VS: 1 присвоение `gl_Position`. FS: не запускается |
| **`deferred.fsh` — небо** | **1** (`depthtex0`) | `colortex0` (4 Б) | ~20 ALU (`normalize(vWorldRay)`, градиент + звёзды + диски) + ~70–100 ALU на облаках |
| **`deferred.fsh` — пещера** (`skyLight ≤ 0.02`) | **3** (`depthtex0`, `colortex0`, `colortex1`) | `colortex0` (4 Б) | ~50 ALU (быстрая `View-Ray` реконструкция, распаковка G-буфера, затенение) |
| **`deferred.fsh` — улица с тенями** | **3** (G-буфер) + **1 / 2 / 3 / 4** `sampler2DShadow` (по умолч. 3; `0` при `NdotL ≤ 0`) | `colortex0` (4 Б) | ~80–110 ALU (`View-Ray` + `sampleShadowMap` + `shadeOverworldSurface` + туман) |
| **`gbuffers_water` — вода** | **1** (`depthtex1`, без `gtexture`) + **1–4** `shadowtex0` | `colortex0` (4 Б blend) | ~105 ALU (без обратных матриц: `opaqueLinearZ`, 3-слойная квинтическая `calcWaterNormal`, `evalWaterReflectionSky`, 2-лепестковый блик) |
| **`gbuffers_water` — стекло/лёд** | **1** (`gtexture`) + **1–4** `shadowtex0` | `colortex0` (4 Б blend) | ~85 ALU (поверхность + градиент неба по Френелю + туман) |
| **`gbuffers_textured` — частицы** | **1** (`gtexture`) | `colortex0` (4 Б blend) | VS: ~45 ALU/вершина (`FORWARD_VERTEX_LIT`). FS: ~15 ALU (текстура + туман) |
| **`forward_common` — прозрачные блоки/мобы** | **1** (`gtexture`) | `colortex0` (4 Б blend) | ~50 ALU (атмосфера уже посчитана в VS) |
| **`gbuffers_weather` — дождь/снег** | **1** (`gtexture`) | `colortex0` (4 Б blend) | ~25 ALU (устойчиво к высокому overdraw) |
| **`final.fsh`** | **1** (`colortex0`) вне конуса солнца; **+9** (`1 + 8` `depthtex0`/`depthtex1`) внутри конуса | Swapchain `RGBA8` (4 Б) | ~50 ALU (`AgX`/`ACES`, `linearToSrgb`, S-кривая, `IGN`) + ~25 ALU в конусе `GOD_RAYS` |

### Итоговая сложность на кадр
При среднем `SHADOW_SAMPLES = 3`:
* На экранный пиксель непрозрачной сцены приходится **~6–7 чтений текстур** за весь кадр суммарно (`gbuffers` + `deferred` + `final`), а на пиксель неба — **2 чтения** (`depthtex0` в `deferred` и `colortex0` в `final`).
* Трафик G-буфера жёстко ограничен **8 байтами на запись** (`R11F_G11F_B10F` + `RGBA8`) и **8–12 байтами на чтение** (`colortex0` + `colortex1` + `depthtex0`).
* В Незере и Энде (`world-1`, `world1`) теневой проход и сэмплирование `shadowtex0` полностью исключены (`O(1)` с малым постоянным множителем).
