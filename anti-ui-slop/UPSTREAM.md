# anti-ui-slop 上游来源

- 上游仓库：[uizze/uizze](https://github.com/uizze/uizze)
- 固定提交：[`40b0ee439ba88aecb65d68bcb379da0e716b899e`](https://github.com/uizze/uizze/commit/40b0ee439ba88aecb65d68bcb379da0e716b899e)
- 上游技能目录：[`skills/anti-ui-slop`](https://github.com/uizze/uizze/tree/40b0ee439ba88aecb65d68bcb379da0e716b899e/skills/anti-ui-slop)
- 本地目录：`anti-ui-slop/`
- 导入日期：2026-10-20（Asia/Taipei）
- 许可证：Apache-2.0；iOS 衍生材料另含 MIT 声明，见 NOTICE；原文见本目录 `LICENSE`。
- 本地包装差异：仅新增本来源记录 `UPSTREAM.md`；上游技能目录内的所有原有文件保持原字节。 `NOTICE`、`MODIFICATIONS.md`、`MANIFEST.json` 和 `CHECKSUMS.sha256` 均来自所列 Uizze 提交，原样保留；其中的衍生来源与改编说明属于上游声明。新增来源记录不写入上游清单或校验和文件。

上游 `SKILL.md` 声明 `metadata.version: "1.3.1"`；`MANIFEST.json` 另保留自身的包版本与逐文件来源，均不以本地记录替换。

## 原始文件 SHA-256

下表来自上述固定提交的文件字节，不包含本地新增的 `UPSTREAM.md`。

| 文件 | SHA-256 |
|---|---|
| `CHECKSUMS.sha256` | `7571c07b5c9031e5d170c8184f9f7d68f7819f7444dce1f951392177a4369f9e` |
| `LICENSE` | `02bb8c3b4e70190e3986c0404ad2fd8d639b4f534252d82379cc1b502b6d1812` |
| `MANIFEST.json` | `85ca2ea5d2d70de7265ea40e50f904cabaa1ef31bb11c23c514b9fca7f5f8904` |
| `MODIFICATIONS.md` | `794dd55db721a88277513667ff983f8e3d95fb2ec67ee5e635ac34bd29126f7f` |
| `NOTICE` | `e05d42aec2a6d4d48cf409c8644ceccdeedfdcbafc4088a6fef25add462ede3c` |
| `SKILL.md` | `c6acdd1865bad4a7f9d381569609cee928c0572e5a0545fba1d8daf6d47616dc` |
| `agents/openai.yaml` | `062dfdfaf388834ea96a5b89ae9722f25ee269a137593099d43afd525d99c571` |
| `reference/audit.md` | `71b4ba9d828697e7b1badc49346c17a5fd5359561e34bb4cf04247b36bb61a6c` |
| `reference/craft.md` | `6d5a51dafd71c51ff8c75026bfa6c6d13fca8fe2f5558ebf2431c5830695a95d` |
| `reference/distill.md` | `5cf9acf215f145ae152a53314f3a95f119b9984aa0cf7da8d61caf75619a65e9` |
| `reference/ios.md` | `f8577af62ab8f1801d415c290656f9e759f8292f9cf83795ee6bcb02d332c213` |
| `reference/new-work.md` | `2c16bfccd77db167976ad3c83a689aa22a8f0bd28f24507397e6b7b3d5e06f7d` |
| `reference/operate.md` | `be6eec1114d122a9a115e31ddf1568567792b33f03ce35ff9e12e96af302696d` |
| `reference/overdrive.md` | `60f4ce940526793d7aa87b4705db3a5b4938ee2efecb6d9f5405a54217e62116` |
| `reference/polish.md` | `8435138f1bf85d93654ca91f0e725bb271d4288ac352c6596e9a64ffcdada651` |
| `references/uizze-reference-policy.md` | `8aa20fa467e80de0503a952b9094d992c93289cd3b397b445fac523071d334ab` |

本仓库是本机管理源；安装副本位于 `~/.agents/skills/anti-ui-slop`，通过仓库根 `sync.sh` 单向同步。
