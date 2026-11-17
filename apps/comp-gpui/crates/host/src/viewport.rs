use gpui_kit::*;

use crate::test_pattern::TestPattern;

pub enum ViewportSource {
    TestPattern(TestPattern),
}

impl ViewportSource {
    pub fn element<V: 'static>(&mut self, t: f32, _cx: &mut Context<V>) -> AnyElement {
        match self {
            ViewportSource::TestPattern(pattern) => {
                pattern.draw(t);
                surface(pattern.buffer().clone())
                    .object_fit(ObjectFit::Cover)
                    .size_full()
                    .into_any_element()
            }
        }
    }

    pub fn stats_lines(&self) -> Vec<String> {
        match self {
            ViewportSource::TestPattern(_) => vec!["source test pattern (host IOSurface)".into()],
        }
    }
}
