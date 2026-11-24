import CoreGraphics
import Foundation

/// The frame a window has part-way through its move from `a` to `b`.
public func interpolate(_ a: CGRect, _ b: CGRect, _ progress: Double) -> CGRect {
    let p = CGFloat(min(max(progress, 0), 1))
    return CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
                  width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
}

extension Config {
    /// A JSON Schema for the config file. Editors with TOML support (Taplo, Even Better TOML)
    /// use it for completion, hover help and validation; the default config points at it with
    /// its first line.
    public static let jsonSchema = """
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "Iguana configuration",
      "description": "Settings for the Iguana window manager. Every setting is optional.",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "gaps": {
          "type": "object",
          "description": "Empty space around and between tiled windows, in points.",
          "additionalProperties": false,
          "properties": {
            "inner": { "type": "number", "minimum": 0, "maximum": 200, "default": 8, "description": "Space between neighbouring windows." },
            "outer": {
              "description": "Space between the windows and the edge of the screen. One number for all sides, or a table with top, left, bottom and right.",
              "default": 8,
              "oneOf": [
                { "type": "number", "minimum": 0, "maximum": 500 },
                {
                  "type": "object",
                  "additionalProperties": false,
                  "properties": {
                    "top": { "type": "number", "minimum": 0, "maximum": 500 },
                    "left": { "type": "number", "minimum": 0, "maximum": 500 },
                    "bottom": { "type": "number", "minimum": 0, "maximum": 500 },
                    "right": { "type": "number", "minimum": 0, "maximum": 500 }
                  }
                }
              ]
            }
          }
        },
        "layout": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "auto-split": { "type": "boolean", "default": true, "description": "A new window splits the focused window along its longer side. When false it is added to the focused window's row or column." },
            "resize-step": { "type": "number", "exclusiveMinimum": 0, "maximum": 0.5, "default": 0.05, "description": "Share of the container that one resize step moves (0.05 is five percent)." },
            "stack-peek": { "type": "number", "minimum": 8, "maximum": 120, "default": 32, "description": "Points of each window in a stack that stay visible behind the window in front." },
            "mouse-follows-focus": { "type": "boolean", "default": false, "description": "Move the pointer to the centre of a window when a shortcut focuses it." }
          }
        },
        "animation": {
          "type": "object",
          "description": "How windows travel to their new place. Switched off automatically while Reduce Motion is on.",
          "additionalProperties": false,
          "properties": {
            "enabled": { "type": "boolean", "default": true, "description": "Windows glide to their new place instead of jumping." },
            "duration": { "type": "number", "minimum": 0.05, "maximum": 1, "default": 0.16, "description": "Seconds a window takes to reach its new place." },
            "easing": { "enum": ["linear", "ease-out", "ease-in-out"], "default": "ease-out", "description": "How the motion is paced." }
          }
        },
        "stage-manager": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "reserve-strip": {
              "description": "Room for Stage Manager's strip of recent apps: \\"auto\\" leaves room while the strip is shown, false tiles underneath it, a number reserves that many points.",
              "default": "auto",
              "oneOf": [{ "const": "auto" }, { "type": "boolean" }, { "type": "number", "minimum": 0, "maximum": 600 }]
            },
            "strip-width": { "type": "number", "minimum": 0, "maximum": 600, "default": 150, "description": "Width used when reserve-strip is \\"auto\\" or true." }
          }
        },
        "menu-bar": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "desktops": { "enum": ["current", "all", "occupied"], "default": "current", "description": "Which desktops the menu bar icon draws: the one you are on, every desktop side by side, or every desktop that has windows." },
            "click-to-switch": { "type": "boolean", "default": false, "description": "With more than one desktop drawn, a click on one of them goes to it instead of opening the menu." }
          }
        },
        "hooks": {
          "type": "object",
          "description": "Shell commands Iguana runs when something changes, for status bars and scripts. Each is run with /bin/sh -c and gets the facts in environment variables: IGUANA_EVENT, IGUANA_DESKTOP, IGUANA_DISPLAY and, for the focus, IGUANA_WINDOW_ID, IGUANA_APP and IGUANA_TITLE.",
          "additionalProperties": false,
          "properties": {
            "desktop-changed": { "type": "string", "default": "", "description": "Run when the desktop a display is showing changed. An empty string runs nothing." },
            "focus-changed": { "type": "string", "default": "", "description": "Run when a different window has the focus. An empty string runs nothing. In a script, write \\"$IGUANA_TITLE\\" with the quotes: a window title can be any text." }
          }
        },
        "bindings": {
          "type": "object",
          "description": "Keyboard shortcuts. The key is modifiers and a key joined by dashes, the value is a command. Leave a shortcut out to keep its built-in command, or set it to \\"\\" to switch it off.",
          "additionalProperties": false,
          "patternProperties": {
            "^((cmd|command|super|ctrl|control|opt|option|shift)-)+([a-z0-9]|minus|equal|comma|period|slash|semicolon|quote|backslash|backtick|leftbracket|rightbracket|space|tab|return|enter|delete|esc|escape|left|right|up|down|f[1-9]|f1[0-2]|-)$": {
              "description": "A command, for example \\"focus left\\" or \\"move-to-space 3 --stay\\".",
              "oneOf": [
                { "const": "" },
                { "const": false },
                { "type": "string", "pattern": "^(focus|move|join) (left|right|up|down)$" },
                { "type": "string", "pattern": "^resize( (width|height))? (grow|shrink)( (width|height))?$" },
                { "type": "string", "pattern": "^space ([1-9]|1[0-6]|next|prev|previous)$" },
                { "type": "string", "pattern": "^move-to-space( (--stay|--follow))? ([1-9]|1[0-6]|next|prev|previous)( (--stay|--follow))?$" },
                { "enum": ["flip", "stack", "balance", "float", "zoom", "close", "pause", "reload", "settings", "tour", "list-windows", "list-spaces", "tree", "status", "quit"] }
              ]
            }
          }
        },
        "rule": {
          "type": "array",
          "description": "Windows that should stay floating. Written as [[rule]] sections.",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "anyOf": [{ "required": ["app"] }, { "required": ["title"] }],
            "properties": {
              "app": { "type": "string", "description": "A bundle identifier (exact match) or part of the app's name." },
              "title": { "type": "string", "description": "A regular expression matched against the window title, ignoring case." },
              "float": { "type": "boolean", "default": true }
            }
          }
        }
      }
    }
    """
}
