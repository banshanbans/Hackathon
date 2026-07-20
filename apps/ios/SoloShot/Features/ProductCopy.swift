import Foundation

enum ProductCopy {
    static func executionMode(_ value: String?) -> String {
        switch value {
        case "fixture", "mock": "演示模式"
        case "live": "实时分析"
        case "cache": "已恢复"
        case "fallback": "稳妥模式"
        case "error": "需要重试"
        default: "等待复盘"
        }
    }

    static func creationMode(_ value: String) -> String {
        value == "scene_adaptation" ? "灵感迁移" : "原图复刻"
    }

    static func cameraHeight(_ value: String) -> String {
        switch value {
        case "ground": "贴近地面"
        case "knee": "膝盖高度"
        case "waist": "腰部高度"
        case "chest": "胸口高度"
        case "eye": "视线高度"
        case "overhead": "高于头顶"
        default: "专属高度"
        }
    }

    static func cameraAngle(_ value: String) -> String {
        switch value {
        case "level": "镜头水平"
        case "slight_up": "轻微仰拍"
        case "slight_down": "轻微俯拍"
        default: "专属角度"
        }
    }

    static func lens(_ value: String) -> String {
        switch value {
        case "0.5x": "0.5× 超广角"
        case "1x": "1× 主摄"
        case "2x": "2× 长焦"
        default: "推荐镜头"
        }
    }

    static func round(_ index: Int) -> String {
        index == 1 ? "第一次" : "调整后"
    }
}
