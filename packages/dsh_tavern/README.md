# dsh_tavern：预设执行与协议边界

本包以 SillyTavern 1.19.0 固定提交 `7e8663cd9c184a550b37238218bdd32c6efc68e9` 为兼容基准。预设的 `raw` / `encode()` 保留原始 JSON 值和未知字段；执行时按具体读取位置转换，不对整个预设做统一强转。

## T19a：宽容读取预设

| 读取位置 | 行为 | 固定 ST 依据 |
| --- | --- | --- |
| 上下文、最大回复的预算计算 | JavaScript Number 语义，然后进入现有整数 token 预算；无效或非有限值用字段默认值 | openai.js setTokenBudget 用 context - response |
| temperature、top_p、presence_penalty、frequency_penalty 请求值 | Number 转换；非有限结果按 JSON.stringify 语义发 null，不改成默认采样值 | openai.js 2803–2810 |
| max_tokens 请求值 | 保留原类型与值；缺失时用默认。数字字符串可参与预算计算，请求仍是字符串 | 前端 2811、后端 1130 直接转发 |
| enabled、continue_prefill、squash_system_messages、stream_openai、show_thoughts | 按 JavaScript 真值读取；非空字符串 false 也是真 | PromptManager 的 entry.enabled &&、openai 直接条件 / Boolean |
| names_behavior、injection_position、injection_depth、system_prompt、forbid_overrides | 保留严格比较；字符串 1 不自动变成数值 1 | openai 的 enum / depth 比较和 forbid_overrides !== true |
| 提示词正文 | 先按真值判空，再 String 转换；false/0/null 为空，true 变文字，数组用逗号连接，对象为 [object Object] | script.js substituteParams 2981–2987 |
| DeepSeek reasoning_effort | auto 不发，min/low → low，max → max，其余包括非字符串值 → high；仅思考开启时发 | openai.js getReasoningEffort 2570–2582 |

预算不能使用 NaN 或 Infinity，有限值回退是本包的明确容错政策，不代表 ST 也回退到 4095/300。请求采样有独立的 Number → JSON null 路径，不能拿预算回退替代。现有预算是整数，有限小数仍沿用整数化；不宣称复刻任意非法预设的浮点预算或 DOM 控件行为。

角色在内部不再触发 String 强转错误：按 ST Message 的规则，假值在生成消息时回退 system；其余原值保留。未知角色仍可能被模型端拒绝，不等于已被验证合法；完整导入校验属于 T20。

continue_postfix 对齐主脚本运行态字符串拼接，cyclePrompt 和 continue_mag 使用同一值。包内既有接口允许任意字符串；ST 的 setContinuePostfixControls 有四选项控件修正，预设切换又会写回原值。本包不模拟整套 DOM 装载流程。开启 continue_prefill 时，发出的前缀仍是原消息；后缀用于本地累计，不为了后缀改写此前已确认的预填充语义。

## T19b：100001 组的选择

ST 使用 global 策略、dummyId 100001，比较 String(character_id)。缺少该组时 sanitize 追加默认 12 项，随后选用它；不回退第一组，也不使用定义自己的 enabled 代替顺序。

第一份匹配的组已经存在，但 order 为 []、null 或缺失时，ST 虽追加默认组，后续 find 仍先命中原来的空组；重复的后组也不覆盖它。本包保留这一结果。空顺序不等于禁止所有独立系统、世界书或控制注入。

ST 对非数组 order 或非对象条目可能抛 TypeError。本包将无法执行的容器视为空顺序、过滤非对象条目，这是明确的畸形输入容错；原 JSON 仍无损保留。规范视图同时供 assembler 和 engine 世界书 section 判断读取。

## T19h：DeepSeek 的 seed

**原生 DeepSeek 请求继续不发 seed；本项只修正说明，不改变这个发送行为。** 固定 ST 前端 seedSupportedSources 不含 DeepSeek；只有来源在列表且 settings.seed >= 0 时才附加 seed。后端虽转发 request.body.seed，正常前端未提供时它是 undefined，JSON.stringify 会省略。

因此，后端支持转发不代表正常 DeepSeek 回合会发送。设计稿 roleplay-compat.md 的 DeepSeek 段中发送 seed 的说法按这里的固定源码证据修正；设计文件不在本次允许修改的 package 范围内，本补丁不编辑它。

通用非 DeepSeek 路径保留已有 seed 功能：按 JavaScript 数值比较判断，再转发原值。字符串 Infinity 比较时为正无穷，发送的仍是原字符串；这不保证提供方接受它。

## 固定来源与验证

- [PromptManager.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/PromptManager.js)，blob 20219dc45ffa232ef61ebbfac0836241f168a55a。
- [openai.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/openai.js)，blob bab82eec57e0927b809b0571534e96f1b13360e1。
- [chat-completions.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/src/endpoints/backends/chat-completions.js)，blob 0d98c77f7b64502c5b0f504eaa1f67df0f26041e。
- [script.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/script.js)，blob 777a2d5983a6283ef9b26726e75192da1e3f3cea。

已执行固定源码方法和请求对象片段的原生 V8 探针；它不是 Dart 测试，也不是完整 ST 浏览器或真实提供方对拍。新增 test/t19_preset_protocol_test.dart 覆盖对应 Dart 行为；实际 formatter / analyzer / 测试结果以 owner 代跑回件为准。

# T20：预设库、选择与增强预填充

## 管理接口

Tavern 提供 listPresets/watchPresets/preset、importPreset、updatePreset、updatePresetPrompt、setPresetOrder、setPresetPromptEnabled、exportPreset、presetSelection、setDefaultPreset、bindPreset、deletePreset。导入传原始 JSON String 与可选文件名；它只保存，不自动选为默认，也不修改配置的模型地址或密钥。返回详情与逐项诊断（severity/code/path/identifier/message）。异常 TavernPresetImportError 带完整错误列表。

sourceText 是不可编辑的导入原文，保留 BOM、空白和换行；raw 是当前完整 ST JSON；envelope 保存可选分享包。已知字段的正规化会指出具体路径，未知字段保留。后续编辑不重写原文。摘要列表只读元数据；详情才取原文和全部 JSON。更新对象递归合并、数组/标量替换，调用时复制输入，队列内取最新记录再合并。

新导入校验唯一非空字符串 identifier、system/user/assistant role、0/1 注入位置和非负整数深度。缺角色、model别名、大小写和可归一化的整数形式会记录诊断；非法值拒绝，不自动改标识符。旧 main_prompt 等无prompts格式仍可导入。首个100001组及空组保持T19语义。单提示词编辑的identifier稳定；顺序助手保留现有entry未知字段和开关，其他组不动。

## 格式与无损范围

识别的增强格式为 [dsh-preset-enhance](https://github.com/bychv/dsh-preset-enhance/blob/a7717ddc76f3985cf6a71ac6ee463911886b15a5/PRESET_FORMAT.md) v1（MIT）。只按确切format识别；该格式的未知主版本拒绝，不悄悄当ST。其他原生ST未知format/version/preset字段仍保留。外层metadata、preset包装、prefill、tools和extensions均保留；保存不代表执行工具、DSML、动态模板或附件。

ST原生导出在extensions.dshgo.presetEnvelope存去掉preset.data的外壳，从当前raw重建data，避免多次往返递归增长。当前独立envelope是外壳权威；其旧prefill开关不在重导入时覆盖已经编辑的dshgo配置。presetEnvelope是导出保留载体，updatePreset及从已有外壳派生的旧map桥接拒绝改变它；结构相同的完整raw回写允许。旧setPreset完整替换且无独立外壳时仍能原样导出旧未知值。

导出不重新套新导入正规化，旧宽容helper接受的role/正文等值不会在出口静默改变。修改库名称会同步现有分享包metadata.name；原生ST名称由调用方导出文件名承载。连接字段也保留，但实际endpoint/model/key只由configure控制。

## 选择、聊天覆盖与旧入口

优先级为有效chat binding、显式chat inline、有效library default、global inline、ST默认。缺失旧ID保留且由presetSelection列出missingPresetIds；新bind/default先验证存在。bindPreset(chat,null)清该chat的已知inline并恢复继承；setSettings({'preset':null},chatId:chat)仍保留旧语义，执行该聊天自己的ST默认。

每聊天采样可写setSettings({'presetOverrides': {...}},chatId:chat)，六个可执行键为temperature、top_p、presence_penalty、frequency_penalty、openai_max_tokens、openai_max_context。覆盖在完整选择后应用，不修改库raw；其他键保留在settings而不进入预设。

旧setPreset是整份替换；旧setSettings里的preset对象只在本scope递归合并。chat不能拿继承的global预设作合并基底。有明确库选择时从它派生新记录并选用，保留原记录、完整外壳和库名称；原inline也同步保留。因此删除库记录与清绑定后，已有inline仍是合法回退，不承诺删掉这个独立配置。完全通过新import/bind/default选用、无inline的记录删除后回默认继承。

原生库和chat混合编辑均用SQL事务。旧global混合入口先写settings.json再改SQL选择，不能跨资源原子；期间新回合busy，已有回合保留快照。SQL第二步失败时新文件内容已提交、旧default仍在，新记录回滚，错误上抛，重开读同一事实。文件第一步失败则不碰SQL，但沿用旧API已更新内存的失败行为；不宣称内存和磁盘一起回滚。编辑库记录、换default只影响后续回合；按聊天选择及删除会取消并等待受影响回合。删除也追踪当前回合先前捕获的ID，覆盖default已经换走的情形。

## 预填充通道与边界

增强设置为extensions.dshgo.prefill的enabled和target。只有enabled为true才解释额外assistant_prefill，或采用明确的末尾预设assistant片段；enabled仅控制增强路径，ST原生正文前缀继续按既有规则。所有来源缺target默认content，以题面为准；增强参考实现自身的隐式reasoning默认不搬入。明确reasoning且当前回合开思考时，新前缀进入最后assistant的reasoning_content，content为空，prefix=true；关闭思考则原文留在content。

正文模式保留原文字节；思维模式只对选中的新片段处理参考实现的leading think/thinking包装，不扫描历史。新思维片段与历史assistant/CCV3正文前缀保持独立边界，不把合并后的历史整条搬进思维。API形状依DeepSeek官方 [Chat Completion](https://api-docs.deepseek.com/api/create-chat-completion/) 与 [前缀续写](https://api-docs.deepseek.com/guides/chat_prefix_completion/)，具体服务端兼容性未以真实付费模型调用测试。

continue回合跳过新增增强预填充并记录exclusion，保留原continuePrefill和postfix语义，不执行被跳过模板的宏。generic连接不假定支持reasoning_content；保留content并给unsupported诊断。非预设尾片段、尾system和空模板不强行移动为前缀。宏只展开一次，预算预留原始新片段，思维输入也计入trace和估算，不按空content记零；这是token估算，不能冒充提供方收费数。

按ADDENDUM-04，增强预填充模式、continue_prefill续写和声明CCV3前缀时，从预算开始就移除新tools/tool_choice。增强模式即使最终空或尾system未形成prefix也不挂工具，明确记录排除；避免为实际不发送的工具预留预算而误报超限。历史tool_call/result配对保留，不执行DSML工具转换。完成输出仍只由模型增量形成，不把请求前缀冒充模型输出落盘。

T20的结构化导入诊断供后续T22体检接入；T22统一持久体检接口尚不属于本层。真实v2逐级迁移、失败回滚、原文/未知字段、选择和前缀均有专项测试；冻结交付说明另列实际运行结果，不能把源码探针或静态阅读当作Dart通过。

外层分享包与内部 `presetEnvelope` 同时存在时，去除外层 `preset.data` 后的外壳必须结构相同（JSON 对象键顺序不影响判断）；不同则以 `conflicting-envelope-carrier` 报出内部载体路径，避免导出覆盖另一份未知数据。内部载体自身含 `preset.data` 也拒绝；它是去掉数据后的分享包元信息，不能递归嵌套预设。


# T21：显示正则与资料库

`displayText(chatId, nodeId:, text:, role:, speaker:, depth:, reasoning:)`返回临时文本、逐规则warnings、replacements和superseded。传nodeId读存储原文，同时传text则使用最新完整流式原文；每次从原文计算，不能叠用上次显示结果。相同chat/node/reasoning最多一个执行中和一个最新待执行版本，App忽略superseded结果。无node时正文/思维各有一个live通道。

只做正则，不渲染Markdown/HTML。变量、历史、hash与随机源均为独立显示副本，不改变真实回合、正文、reasoning、检视或导出。按固定ST messageFormatting，隐藏消息仍做显示正则，但不计自动depth；真正is_system且名字为SillyTavern System才跳过。raw无自动depth，raw system缺speaker时用系统名；自定义旁白请传speaker给trim宏。

显示和WI正则使用两个独立常驻Isolate。默认每次200条实际规则，原始输入/模式512KiB UTF-8，最终及链间文本2MiB，累计替换20000次，单派发请求1.5秒；内部捕获描述预算2MiB，最多64个等待命令。超时返回跳过并请求immediate kill，旧onExit确认后才重生，epoch/id拒绝旧结果。实际退出和Timer受VM调度影响，期限不是整个API的硬完成时间。宏、纯文字匹配、替换构造仍在owner；prompt/writeBack保持旧同步路径。

失败只丢本条文本，保留前序成功文本和已发生的临时宏效果。捕获模板逐步限制增长；宏前上限为输出预算与原模板大小的较大值，允许长模板经宏收缩，宏后严格检查最终输出。WI的skipped为不可判定，按候选跳过，不可当false再经NOT/exclude反向命中。取消在受控await前后检查。原生未识别literal仍回退纯文字；已识别但编译失败跳过，是T21保护政策。

新卡、预设、世界书及正则导入会试编译静态输入，动态宏只标deferred并延到运行检查；原始JSON不因诊断被改写。script历史flags fallback、native和V3方言分开。卡/预设/世界书的regexDiagnostics仅为导入回执；全局库诊断随记录保存，统一持久体检属于T22。

全局库接口：listRegexScripts、importRegexScripts、setRegexEnabled、deleteRegex、exportRegex。单对象/数组均接收，内部ID独立于ST id；原文、未知字段、原开关及诊断保存。执行view跳过不兼容规则。顺序：旧inline global→管理库→preset→card；managedRegexScripts是设置合并后的只读投影，read→set不能重复或覆盖库。在途回合保留已捕获规则。

世界书接口：listLorebooks、importLorebook、lorebook、putLorebook、exportLorebook、deleteLorebook、bindLorebooks。可绑定global、characterId、chatId、personaId。删除保留绑定，下轮记missing并跳过；已捕获书的回合继续。

filename去路径及.json后另存stWorldName，不能用raw.name显示标题代替来源；仅当raw缺name才以filename补显示名。raw与来源在同一个本地envelope原子发布，旧raw文件仍可读，公开读/导出只含原生raw。summary.stWorldName供导出命名，put保留来源。当前分支world_info对应的精确stLorebookIds映射优先，并统一同ID各scope的原生timer hash/key；无来源证据才回退本地ID。read/put/delete同队列，同时捕获raw与来源；不承诺跨多个资源事务。

新测试登记207例：worker19、protected display115、WI34、façade/library33、来源身份6；已有113例WI及105例同步regex保留。登记数不是通过数，实际format/analyze/test和平台退出结果以owner回执为准。来源固定ST 1.19.0提交7e8663cd的public/script.js、regex、utils和world-info；未读JS-Slash-Runner。


# T22：持久化导入体检

四个新导入入口（importCard / importPreset / importLorebook / importRegexScripts）会保存结构化能力报告。App可在角色页或对应资料详情页常驻展示；本层只提供数据和接口，DeferredTavern / PreviewTavern转发由主线补。

| 接口 | 合同 |
|---|---|
| readImportReport(kind, assetId) | 读已保存报告；旧资料没有报告、或资源已不存在时为null。不会试编译、展开宏或执行脚本。 |
| recheckImport(kind, assetId) | 对当前资料显式重检并保存；缺失资源报错。复用T21受控编译，不执行用户宏或脚本。 |

kind为character / preset / lorebook / regex。报告包含version、checkedAt、counts、verdict、findings、renderLevel、fingerprint和stale。三个总评为usable（能用）、partial（部分能用）、preserveOnly（只保留不执行），描述已识别的能力，不保证动态内容在所有场景均会生效。用户关闭的条目、空合法书或未触发的关键词不是兼容错误。

每个finding单独带path、code、message、kind；可带identifier、原文行号及从零计的UTF-16 offset，conditional/fallback保留条件与后备路线。unsupported表示已知未实现，invalid表示该已知结构或模式无效，deferred表示需运行时上下文，unknown表示不解释的保留数据；条件性结果不冒充无条件失效。数量是声明及检查的数量，不能当作本次执行次数。原生书的存储条目、V3去重后的执行条目分别计数。

报告是checkedAt时的快照。fingerprint对已检查的JSON、独立预设外壳和嵌入资源路径作规范化哈希；对象键序不影响，数组顺序有意义。此值用于检测编辑，不是签名，也不判断未读取的资源内容。编辑后读出旧报告并标stale，直到显式重检。重检保留原文、当前raw、库名、选择和内容更新时间；不会趁机正规化宽容旧预设。引擎版本升级可能增加能力，旧报告仍是原检查时刻的记录，可显式刷新。

渲染级别仅是建议：0原生、1单消息WebView、2整页画布。2需要明确脚本、助手依赖或跨消息样式证据；说明里提到插件名称、普通HTML、CSS字符串或代码示例不足以判定。后端不启用任何WebView或脚本执行。静态未发现HTML不能证明运行时宏或正则结果不会生成HTML。

保存边界：卡的report文件在同一个staging目录里随整卡rename发布；预设nullable import_report_json在schema3的同笔INSERT保存；正则report跟随其资料记录；世界书report和原生来源名跟raw同一个本地外壳发布。报告读取与编辑/删除共用所属资源队列。读取角色报告只读card.json和资源清单，不加载原始卡、头像或所有资源字节。重检失败保留旧报告，删除随资料删除。

角色报告读取仍沿用旧_tidy清理残留，因此不承诺绝对零文件写。正则重检同时刷新T21的diagnostics，可能改变后续回合的兼容执行资格；原始数据及disabled不变。数组正则初报使用原$[i]，按单个ID重检使用当前单条的$；不是所有报告路径都对应保留的sourceText。

schema0/1/2通过原有逐级事务迁移到3，既有预设报告为null，不伪造“零问题”。旧裸世界书、T21带来源名的外壳、无报告的regex记录继续读取；无文件名的世界书可用新外壳保存report而不虚构stWorldName。导出不把内部报告混进卡、预设、正则或世界书原生JSON。

非法顶层输入继续按原入口拒绝，不生成不存在资源的“只保留”记录。低层CharacterLibrary/ChatStore及旧setPreset/setSettings宽容桥接可以产生无报告旧式记录；显式recheckImport为这些记录补报。新导入的regex数组逐记录保存报告，保留原数组位置。

中央检查把每处脚本、助手脚本或变量配置、无效正则、未实现的世界书特性、banned宏分别定位。未知供应商字段保持不解释；正常空返回宏、禁用条目和条件性装饰器不冒充引擎缺失。预设附件逐项定位，分享包的工具转换、正文提取、自定义工具后前缀分别提示。正则只使用T21已有受控试编译回执，不再执行第二次编译，动态输入仍为deferred。

HTML/CSS只是有限的静态正面检测：资源路径参与计数和fingerprint，资源字节不扫描；不展开实体、CSS转义、srcdoc、宏或正则动态输出，不下载远程内容。Markdown代码、HTML注释、JSON数据script和普通插件名称不作为脚本证据。0不构成动态输出无脚本的保证，2也不表示后端会执行脚本或改变用户开关。

新增110项登记用例：中央分类60、世界书27、存储及迁移8、四类入口集成15。包括旧库补报、编辑后stale、真正v2升级、SQL及文件发布失败、重开/导出隔离、静态检测正反例。110是运行前登记数；实际结果以正式交付回执为准。本层同时修正032指出的4项T21样式info（两处花括号、worker惰性空值赋值、fixture空值元素），不改变其判断或断言。

本层静态分类与持久化测试尚须owner运行。固定ST原文、Python SQLite辅助验证、词法检查和独立源码复核均不替代Dart formatter/analyzer/test结果。

# T23：流式持久化、历史与缓存

流式增量仍立即发事件，正文落盘改为约500ms的dirty检查点，不再每16个增量写入。schema4新增影子正文/reasoning；周期写入不改usage、检视、变量、original或FTS。终态以一个FULL事务保存最终正文、usage、状态与检视，并更新FTS；NORMAL仅用于正文检查点，其他聊天普通写入仍用FULL。重开推广未完成检查点，清除不再对应这份正文的旧usage/检视，不伪造完成状态。

历史改为共用递归CTE，任意叶的完整history不受path默认60条限制；父指针决定顺序，完整路径检查环、断链和跨chat引用。每回合复用一个MacroContext及活历史投影，每次expand仍重新求值，不缓存变量、随机、original或字段结果。固定正则共享，legacy动态编译和普通WI整词编译各有最多1000项LRU；T21用户正则worker保持。

角色列表只读小摘要索引。`watchCharacters()`中的description、creatorNotes、greetings和regexDiagnostics为空，进详情用`character(id)`，字段编辑用`characterFields(id)`。缺索引旧库只从两个JSON恢复；完整记录按id最多缓存最近8项，失败/缺失可重试，编辑只刷新对应项。头像路径沿用既有portrait.png，没有新增图片缩放。

详细的事务、故障恢复、列表合同、模拟清单和仍在调用方isolate的成本见[性能说明](docs/performance.md)。本轮没有搬迁整个引擎或实测手机帧率；500ms全文快照仍有累计文本量可随回复长度二次增长的边界，不能宣称总体已经O(n)。新增100项是运行前登记，实际验证以精确补丁回执为准；033的35条样式info作为本层等价改写处理。

# T24：离页接回、撤销删除、搜索、用量与整库备份

## App 接口及行为变化

| 接口 | 合同与新增理由 |
| --- | --- |
| `resumeTurn(chatId)` | 首次监听时接回当时的活动回合；先给 `TavernTurnSnapshot` 全文，再收后续增量和终态。 |
| `deleteFrom(chatId, nodeId)` | 改为返回 `Future<String>` 撤销 token，先软删整棵子树；原来只 await 的调用方可忽略返回值，接口实现者须转发 String。 |
| `undoDeleteFrom(chatId, token)` | 同一开库会话内恢复该批次，返回 bool；有后续树变更时保留当前路径。 |
| `searchChat(chatId, query, limit: 50)` | 指定对话所有未删除分支的字面子串搜索，返回消息及实际用量，按节点创建顺序从新到旧。 |
| `TavernMessage.reportedUsage` | nullable 的提供方实际用量；批量 path/search 无须逐条重建检视。 |
| `backup(destinationPath)` | 无活动回合时捕获数据库及文件快照，生成 ZIP，返回 `TavernBackupInfo`。 |
| `restoreTavernDirectory(archivePath, directory)` | 顶层恢复函数；目标须关闭，先验证及迁移 staging，成功后重新 open。 |

这些 api.dart 变化承载 App 需要的状态和操作结果。本包没有修改 App 转发或页面。TavernBackupInfo 的 createdAt/sqliteUserVersion/fileCount/totalBytes 描述源快照；字节数是普通 payload 文件的未压缩总量，不含 manifest，恢复迁移后不改称目标目录统计。

## 回合与观察者

send/regenerate/continueReply/impersonate 仍在首次监听时接纳回合。取消订阅只移除该观察者，零观察者时生成、正文写回、检视和用量仍继续；stop、树修改或 close 才明确取消。调用方要停止模型请求须调用 stop，不能再依赖 subscription.cancel。

resume 的查找、登记和完整快照在一个同步段完成。创建 Stream 后延迟监听，以实际监听时的回合为准。准备阶段 snapshot.message 为 null，之后收到 Started；已有消息时快照来自内存，包含未到500ms检查点的全文、续写前缀、允许的思维和本次报告。后续不重放旧 Started 或旧增量。没有活动回合则空流关闭，改从 path/inspectTurn 读持久结果。

观察者互不取消，终态关闭不等待暂停订阅的 close Future。暂停订阅仍可能由 Dart 积压事件，不能将“没有全局重放日志”解释为总内存恒定。接回限于当前引擎生命期，不承诺进程重启后恢复原 HTTP 连接。参见 Dart [StreamController](https://api.dart.dev/dart-async/StreamController/StreamController.html) 和 [close](https://api.dart.dev/dart-async/StreamController/close.html) 合同。

列表订阅的快照也属于引擎管理的异步工作。取消订阅停止通知，已经开始的角色索引读取或恢复仍会完成；close 等这些实际读取结束后才关闭数据库、释放目录所有权。开始关闭后不再启动新的列表读取，也不等待暂停的界面订阅消费事件。备份捕获期间的新列表读取等待捕获结束；这个等待不加入备份正在排空的操作集合，因此不会形成互相等待。捕获成功或失败都会释放等待者。

## 删除、变量与后续工作

schema5 增加删除批次、节点标记和树 revision。软删保留节点身份、正文、父边、seq、内部记忆选择、state、extra/original，不借用 ST hidden。正常节点、路径、兄弟编号、导出和搜索排除标记节点。低层 ChatStore.deleteFrom 仍立即删除，供空失败回合回滚；用户 façade 使用 softDeleteFrom。

删除与选路、当前变量/运行态恢复、latest 检视清理在同一外层事务内；撤销也一起恢复可见性和当前变量。节点自身的检视及实际用量保留，撤销不把旧调用重新记成 latest。无后续树变更时恢复原选择；新回复、正文编辑或分支 ABA 都推进 revision，此后撤销只恢复分支，保留当前路径及变量。普通 updateChat 的变量/metadata 收尾不推进 revision。

重叠删除保留各自 token；另一个已删祖先未恢复时返回 false 且不消费子 token。未知、已使用或已清理 token 返回 false，不能跨聊天使用。删除活动子树先经既有 mutation 屏障完成取消/部分正文收尾，再标记子树。

采用题目允许的“下次打开真删”，没有 timer，close 本身不清理。下次 ChatStore 初始化在 FULL 事务中清待删行及批次，再推广其他 pending 正文。恢复的 staging 试开也属于新会话，因此恢复后不能再撤销上个会话的删除；备份不重开原库，原库 token 仍有效。物理删除用原 FTS trigger 清旧词，软删/撤销不反复写索引。

## 字面搜索与 reportedUsage

新搜索查 text/speaker，包括非当前分支和 ST hidden，不查思维链。绑定参数的 LIKE 以 ! 为 escape，依次转义 !、%、_；引号、反斜线、FTS 操作符样式均按字面处理，中文短词可命中。采用 SQLite 原有 ASCII 大小写规则，不承诺全 Unicode 折叠。先验证 chat；空白 query 或 limit=0 返回空，负 limit 抛 ArgumentError。旧低层 search 保留 MATCH 高级语法。

SQL 排除已有 shadow 的 pending；façade 另排除活动回复，覆盖首检查点前的 continue 旧正文/旧报告和空 reply 的 speaker 命中。每 chat 至多一个活动回复，正 limit 多取一条、过滤后截取，补足正常结果。搜索不取消生成或改变路径。

reportedUsage 为 promptTokens/cacheHitTokens/completionTokens 与可选 model。缺失是 null，真实零保留对象，不从估算或旧 usage 填充。小列只从 version/chatId/nodeId 匹配的 owned inspection 派生，迁移也检查类型。path 不重建 prompt/trace，但 SQL 仍选择节点其他列，不宣称完全不读 extra 字节。

续写只用本次报告，不借之前计数，也不是累计费用。普通手动编辑保留原生成报告；无正文/思维而回滚的失败续写保留原消息及其报告，失败调用另记无 node 的检视。崩溃重开推广 pending 时清过时报告，不虚构最终 token 或价格。

## 备份和恢复的边界

backup 在首个 await 前拒绝活动回合和另一备份，阻止新操作/回合；等待此前已接纳操作以及已经启动的列表快照读取完成，后来的列表读取延迟到捕获结束。SQLite 使用 [online backup API](https://www.sqlite.org/backup.html)，不拼接活 main/WAL/shm 文件。固定 sqlite3 3.9.1 用 `backup(target, nPage: 1024).drain<void>()`，native stream 真正结束后才关目标，不用 timeout 提前放弃句柄。[固定版本源码](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/sqlite3/lib/src/ffi/implementation.dart)

全部文件 staging 完成后释放写屏障，哈希和压缩在辅助 isolate 读取不可变副本；close 等到整个备份及清理完成。ZIP 必须写在活库/快照外，完整关闭后 rename 发布，之前的编码失败不覆盖旧 ZIP。

快照保留所有聊天分支/预设/状态，角色原件及资源、世界书、正则、设置、人设和其它普通文件。只排除明确的存储临时位置、SQLite sidecar、可重建的根 character-index；资源中的 .writing 不按全局后缀过滤。内部链接/特殊文件明确报错，不跟随根外或静默漏备。目录别名统一规范身份，路径可表示性和冲突按宿主平台检查。

Persona 绝对头像只有位于库内且文件已打包才记录 id/sourcePath/path 映射。恢复先核原字节 hash，再只搬迁匹配的已知 avatarPath 到最终根；未知 JSON 中同样字符串、外部/相对/缺失引用均不改，不下载外部资源。原文、未知字段和 opaque 文件不通过重新 import 改写。

恢复先验 manifest 版本、路径/重复、实际解压长度及 SHA-256，再验实际 SQLite user_version、integrity_check、foreign_key_check。旧 schema 仅迁移 staging；现有 settings/persona/regex、角色 metadata/体检、预设详情/体检、世界书 loader 验本应用版本，不重新编译规则或解释资源，不声称验证所有业务损坏。全部 handle 关闭后才移动目标。

父目录 journal 记录 prepared/committed/rolledBack。open 先恢复 journal 再创建根：未提交状态回滚，已提交状态保留新根并重试清理；矛盾或损坏状态留证拒绝误建空库。提交后的清理失败保留日志，不谎报核心恢复失败。同 isolate 拒绝相同或祖先/后代的活库与恢复根；跨 isolate/进程仍要求单 owner，没有 OS 锁。未实现父目录 fsync，不把进程中断恢复扩称为任意断电保证。

备份需要额外 staging/ZIP 空间，未量测手机耗时或峰值内存。归档模块测试以合成字节模拟数据库回调，只测打包协议；store 测试用真实 SQLite backup；façade 测试以受控模型事件覆盖接回、变量/撤销、用量、搜索、整库往返、维护屏障、关闭、版本及工厂恢复。实际 Dart 结果以精确补丁回执为准。


# T16：世界书编辑、分支树、手动消息与卡外观

## App 接口及入口选择

本层按 TASK 的 a–e 与 ADDENDUM-03 的 f 一起实现，接在 T24 之后。新增接口都通过现有异步操作登记，因此 close 等待已接纳工作，T24 捕获备份时新操作按 busy 合同拒绝。App 的 DeferredTavern / PreviewTavern 转发及 UI 由主线补，本补丁不修改 App。

| 入口 | 返回与用途 | API 变化原因 |
| --- | --- | --- |
| `addCharacterBookEntry(id, entry)` | 更新后的完整角色 | 卡内书追加条目；不存在时创建 V3 书 |
| `updateCharacterBookEntry(id, index, fields)` | 更新后的完整角色 | 按原始 entries 数组下标修改，不按排序位置或 uid |
| `deleteCharacterBookEntry(id, index)` | 更新后的完整角色 | 删除该条目，保留其余原件 |
| `previewCharacterBook(id, text, chatId:, seed:)` | `Map<String,Object?>` 世界书阶段 trace | 编辑器“测一下”，复用现有命中、跳过和正则诊断 |
| `tree(chatId)` | `List<TavernTreeNode>` | 整棵可见保存树，提供 parent、role、speaker、preview、at、当前路径、兄弟序号、hidden、branchName |
| `nameBranch(chatId, nodeId, name)` | 完成后通知现有 pathChanges | 给某分支起名，null / trim 后为空时清除 |
| `deleteMessage(chatId, nodeId)` | 完成；没有撤销 token | 只永久删除一条，孩子接到原父节点 |
| `sendOnly(chatId, text)` | 已保存的 `TavernMessage` | 只追加用户消息，不生成回复；空字符串也追加 |
| `narrate(chatId, text, speaker:)` | 已保存的 narrator 消息 | 直接旁白文本入口，不生成回复 |
| `readVariables(chatId)` | 当前末节点已保存局部变量的深复制 Map | 给状态面板只读显示；空的选中路径返回 `{}` |
| `TavernCharacter.theme / assets` | 原始主题 JSON，以及 `TavernCharacterAsset` 列表 | 完整详情提供外观；两个参数可省略，旧 DTO 构造继续有效 |

`watchCharacters()` 保持 T23 的轻量摘要：theme 为 null、assets 为空；请调用 `character(id)` 取得完整外观。导入和编辑返回的是完整角色。资源 DTO 的 type/name/uri/ext/localPath 均为可空 String，原声明中的其他形状仍保留在 `characterFields` 与导出原件中。

## a. 卡内世界书写入和预览

条目编辑支持卡内书的普通 V3 字段及 extensions 中的 ST 位置、深度、顺序、概率、次关键词逻辑、常驻与分组设置。已知字段校验类型和有限整数/数字，未知合法 JSON 仍保留；对象扩展递归合并，数组和标量整体替换。调用时先深复制输入，排队后取最新原件再合并。index 始终是原 entries 数组下标，显式重复 ID 可分别编辑；旧 native 对象型 entries 仍可读和预览，但此写入 API 明确拒绝它，不静默转换为 V3 数组。

id 不能由调用者修改。实际编辑前把旧缺失/null id 固化为原数组下标，再为新增项分配未占用的非负整数。显式异常/重复 ID 保留；null→下标会改变该条目的运行身份，可能使它旧的 timer 身份失效，不能声称所有历史计时键恒定。空更新验证角色和下标，但不固化 ID、不改 modification_date、不重写源卡或索引；删到零条仍保留空书和书级未知字段。

保存复用 T23 的提交顺序：先准备新卡与摘要，再使旧摘要失效，原子发布 card.json，最后尽力发布派生摘要。无法先移除仍可读的旧索引就不发布新卡；卡已提交而索引重建失败不把成功保存谎报为失败，下次列表修复索引。原件、PNG、resources、library metadata 和已有体检报告字节不因此重编码。成功后只替换对应角色的详情 LRU，并刷新摘要列表，不恢复全量读卡或逐 chat 统计。

T22 报告保持原件和检查时间；真实卡指纹改变后读取为 stale，显式 `recheckImport` 才更新。世界书编辑不自动执行关键词试编译或重做体检。theme / localPath 的只读投影不参与指纹，不会仅因目录搬家使报告过期。

预览在首次文件等待之前捕获当前对话、变量、历史、人设、有效预设和设置；用独立 seed 的随机源和局部/全局状态副本。先固定预设，再建立单次宏环境；用户写回正则和宏、角色准备、提示词历史与扫描注入按现有阶段执行；世界书求值 await 引擎的常驻关键词 worker。只传当前卡内书，不混入另外绑定的全局、人设、对话书。

返回 scope=`character-book`、stage=`world-info`、seed、chatId、contextNodeId 以及现有 trace。正常 sticky/cooldown/decorator 规则在副本上执行后丢弃，不用改变语义的 dryRun 替代。没有完整组装最终 prompt，因此 contextAtCapacity 保持未知，不保证某条最终一定送达模型。不创建 turn、不调用模型、不取消现有回合、不保存变量、计时器、检视或使用量；关键词诊断沿用 T21。写回和 prompt 正则仍采用现有同步实现，不能把关键词 worker 的保护外推为整次预览都在 isolate 内。

## b/c. 树、分支名与两种删除

整树按插入顺序返回全部可见保存节点，不受 path 默认 60 条限制；包括非当前分支和 ST hidden，排除 T24 软删节点。preview 是原文前 64 个 Unicode code points，不拆合法代理对，不运行宏、正则或 Markdown。活动回复只读已经保存的正文/checkpoint；要接回实时全文请用 T24 的 resumeTurn。

分支名存于 `extra.dshgo.branchName`，仅合并这个字段。命名先取消并等待该聊天的活动回合，再读取最新 extra，因此不覆盖取消收尾写入的检视、使用量或状态。同名/清理本已缺失的字段不写；实际改名推进树版本，旧撤销 token 仍可恢复分支可见性，但不覆盖之后的选择。

| 操作 | 被移除的内容 | 选择和状态 | 撤销 |
| --- | --- | --- | --- |
| `deleteMessage` | 一条可见节点，所有物理直接孩子重挂；包括待撤销孩子 | 幸存节点 ID、正文、报告及未知数据不变；当前末节点若正是目标则退到父/空路径；否则保留末节点 | 没有 token，永久删除 |
| `deleteFrom` | T24 的整棵物理子树软删标记 | 当前路径退回保留部分并恢复其局部状态 | 返回 token；下次打开前可撤销，后续树版本影响选择恢复 |

单条删除前分别保存两种状态：物理父链重建值写成每个直接孩子的完整 checkpoint；孩子的 portable tavernState 另存于原 extra，不能拿它替换物理基底，否则会污染更深后代的 delta。旧快照缺少 hash 标记时，在改边前按该孩子自己的来源 header 补齐；显式 null 与 0 均保留。更深后代的 delta/full 不变，全部物理后代深度减一。后续 append 同时按实际 delta 距离建检查点，保持最多 19 个 delta，而不只看已经改变的深度取模。

结构修改、当前局部变量/运行 metadata 恢复、失去有效锚点的 latest inspection 清理放在一个 SQL 事务内；成功提交后才清内存变量/检视缓存。取消回合的既有收尾可先产生效果，删除本身不重放宏、不改全局变量。旧子树 token 若记录了已永久删除的父/选择，单删会推进 tree_revision，使 undo 只恢复实际新父边上的可见性，不复活历史父节点。待删节点不能作为单删目标；普通读写也不能绕过软删可见性。

## d/e. 手动消息与保存变量

`sendOnly` 对原始 text 先执行 USER_INPUT 写回正则，再展开一次宏；不先 trim，结果为空仍入树，speaker 取当前人设名。`narrate` 先按 JavaScript 的 25 个空白/换行码元集合 trim，再展开宏，不执行 placement 3；NEL U+0085 保留。speaker 显式参数（包括空串）优先，其次为有效 metadata 中非空 String 的 narrator_name，最后为 System。节点可见、role=narrator、extra.type=narrator。

两入口先取消并等待当前回合，随后沿此时选中末节点追加；不另外执行 prepareCharacterFields、首条历史重写、WI、完整 prompt 或模型调用，保留前次请求检视。旧宏模式自身的 eager 卡字段读取仍然执行，这是已有宏语义，不能误写为“绝无卡字段副作用”。旁白入口只对齐直接 handler 的正文阶段，不模拟 slash parser 的前置参数展开、bias、at、compact 或 avatar 参数。

局部变量在副本里计算，与新消息和运行 metadata 一起提交；timer/decorator/greeting、JSONL 来源、chat identity 与 hash 跟随选中状态。已改变的全局变量先持久保存，再进入 SQL 事务。准备失败时仍保存已经发生的全局准备效果；若保存也失败，错误载体保留原准备错误、保存错误及各自 stack。准备成功但保存失败不会追加消息；之后 SQL 失败会回滚消息和局部状态，而已经保存的全局准备效果保留。这是新手动入口的明确顺序，未更改旧 createChat 的既有顺序。

`readVariables` 只读末节点保存的 effective state，优先 portable override，否则物理快照；其 variables 缺失时为空，不从 chat 级或 live cache 补值，不包含 globalVariables。读取不保存、不取消、不运行宏、不消耗随机数，返回嵌套 Map/List 的独立副本。即使还有未选中的根节点，空的选中路径也返回 `{}`。

## f. 外观与本地资源

theme 是 `extensions.dshgo.theme` 的 JSON 深复制，对象、数组和标量都原样提供，缺失或 null 仍为 null，不解释颜色/字体、不增加默认值、不暴露其他 extensions。assets 保留对象成员的声明顺序，type/name/uri/ext 是字符串才投影；其余原值仍在完整卡 JSON 中。

已物化的 `embeded://`、`embedded://`、`__asset:` 与 CHARX 安全相对引用给出当前角色目录中的 resources 路径；`ccdefault:` 在保有原 PNG 时指向 source.png，不拿 portrait.png 代替原始动画/容器。远程 URL 保持原 uri，localPath=null；不下载，不把 arbitrary file URI 当本地资源，不做 URI 百分号解码。路径只在记录运行时保存，不写入卡、metadata、摘要索引或报告；整库移动、T24 恢复到新根后，重读详情按新根生成路径。

localPath 表示当前已载入记录的物化位置，不能保证面对外部删除文件后仍永远存在；不为每次 DTO 投影额外扫盘。摘要构造直接读取小字段并复用 regex/script 计数，不先展开主题和资源再丢弃，因此列表和索引恢复继续保持 T23 的轻量职责。

## 来源与测试边界

ST 对照固定为 `7e8663cd9c184a550b37238218bdd32c6efc68e9`（AGPL-3.0）：[script.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/script.js) 的普通删除及 sendMessageAsUser、[slash-commands.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/slash-commands.js) 的 sendNarratorMessage。这里对齐正文阶段和“仅删该条、保留之后消息”；树边、checkpoint 与撤销 token 是本项目存储适配，不声称 ST 原生也具有相同树模型。

本层以临时真实 SQLite/文件/ZIP、真实正则与宏做回归；模型事件、时钟和随机源使用受控 fixture，不发生真实计费。SQL 触发器和 settings.json.writing 目录用于真实失败路径；外观回归的 loopback 服务只统计是否发生不应有的下载。没有把源码阅读、Python SQLite 探针或 V8 空白谓词对照算成 Dart 通过。准确注册数、冻结 SHA、独立复核与 owner 运行结果记录在本层交付 README/REVIEW；旧 027/028 只适用于旧 T16a/b 层叠。
