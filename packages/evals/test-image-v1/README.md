# Test Image v1 使用说明

本目录是 SoloShot AI H5 公开预设和内部参考图评测的唯一素材来源。

## 目录约定

- `manifest.json`：案例元数据、人物框、预期分析、ShotPlan 和评价 Fixture。
- `manifest.schema.json`：私有数据清单校验规则，不属于公开 API。
- `assets/references/`：保留原始 JPEG，不覆盖、不放大、不去除水印。
- `apps/h5/public/presets/test-image-v1/`：由 `make seed-demo` 生成的 WebP 派生资源。

## 实拍配对待办

公开的 4 个案例在启用真实模型质量结论前，需要各补充两张实拍图：

```text
assets/captures/{case_id}/round-1.jpg
assets/captures/{case_id}/round-2.jpg
```

拍摄时使用同一设备、方向、场景和光线。Round 1 只制造 `manifest.json` 中指定的一个主要问题，Round 2 只修正这一问题。素材未补齐前，H5 必须持续显示“Fixture 状态模拟”，不得把评价描述为实时模型实测。

## 验证

```bash
make seed-demo
make evals
make test-h5
make e2e-h5
```
