use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::OnceLock;

use gpui_kit::*;

const FONTS: [&[u8]; 7] = [
    include_bytes!("../assets/fonts/Inter-400.ttf"),
    include_bytes!("../assets/fonts/Inter-500.ttf"),
    include_bytes!("../assets/fonts/Inter-600.ttf"),
    include_bytes!("../assets/fonts/Inter-700.ttf"),
    include_bytes!("../assets/fonts/RobotoMono-400.ttf"),
    include_bytes!("../assets/fonts/RobotoMono-500.ttf"),
    include_bytes!("../assets/fonts/SF-Pro-400.ttf"),
];

const LUCIDE_JSON: &str = include_str!("../assets/icons/lucide.json");
const LUCIDE_PREFIX: &str = "lucide/";

// Sonner's built-in success and error icons (sonner/dist assets).
const SONNER_SUCCESS: &str = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" height="20" width="20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z" clip-rule="evenodd"/></svg>"#;
const SONNER_ERROR: &str = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" height="20" width="20"><path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-8-5a.75.75 0 01.75.75v4.5a.75.75 0 01-1.5 0v-4.5A.75.75 0 0110 5zm0 10a1 1 0 100-2 1 1 0 000 2z" clip-rule="evenodd"/></svg>"#;

pub fn register_fonts(cx: &mut App) -> anyhow::Result<()> {
    cx.text_system()
        .add_fonts(FONTS.iter().map(|b| Cow::Borrowed(*b)).collect())
}

fn lucide() -> &'static HashMap<String, String> {
    static ICONS: OnceLock<HashMap<String, String>> = OnceLock::new();
    ICONS.get_or_init(|| {
        let parsed: serde_json::Value = serde_json::from_str(LUCIDE_JSON).unwrap_or_default();
        parsed
            .get("icons")
            .and_then(|v| v.as_object())
            .map(|icons| {
                icons
                    .iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                    .collect()
            })
            .unwrap_or_default()
    })
}

pub fn lucide_path(name: &str) -> SharedString {
    format!("{LUCIDE_PREFIX}{name}.svg").into()
}

pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        match path {
            "sonner/success.svg" => return Ok(Some(Cow::Borrowed(SONNER_SUCCESS.as_bytes()))),
            "sonner/error.svg" => return Ok(Some(Cow::Borrowed(SONNER_ERROR.as_bytes()))),
            _ => {}
        }
        if let Some(name) = path
            .strip_prefix(LUCIDE_PREFIX)
            .and_then(|p| p.strip_suffix(".svg"))
        {
            return Ok(lucide()
                .get(name)
                .map(|svg| Cow::Owned(svg.clone().into_bytes())));
        }
        Ok(None)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        if path.starts_with(LUCIDE_PREFIX) || LUCIDE_PREFIX.starts_with(path) {
            let mut out: Vec<SharedString> = lucide().keys().map(|k| lucide_path(k)).collect();
            out.sort();
            return Ok(out);
        }
        Ok(Vec::new())
    }
}
