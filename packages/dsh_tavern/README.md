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
