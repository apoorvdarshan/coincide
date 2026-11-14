//! Fit a page whose document is wider than the browser pane. Responsive pages
//! stay at normal zoom; an agent's explicitly requested viewport takes priority.

use serde_json::Value;

const MAX_CONTENT_WIDTH: f64 = 8192.;
const MIN_ZOOM: f64 = 0.1;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Measurement {
    viewport: f64,
    content: f64,
}

/// IPC comes from a web page, so accept only bounded numeric measurements.
pub(crate) fn measurement(body: &str) -> Option<Measurement> {
    if body.len() > 256 {
        return None;
    }
    let value: Value = serde_json::from_str(body).ok()?;
    if value["kind"] != "coincide-page-width-v1" {
        return None;
    }
    let viewport = value["viewport"].as_f64()?;
    let content = value["content"].as_f64()?;
    if !(40. ..=MAX_CONTENT_WIDTH).contains(&viewport)
        || !(40. ..=MAX_CONTENT_WIDTH).contains(&content)
    {
        return None;
    }
    Some(Measurement { viewport, content })
}

#[derive(Default)]
pub(crate) struct PageFit {
    content_width: Option<f64>,
}

impl PageFit {
    pub(crate) fn reset(&mut self) {
        self.content_width = None;
    }

    /// Ignore observations from an old layout, including transient native
    /// screenshot resizes. Zoom changes may produce one-pixel rounding.
    pub(crate) fn observe(&mut self, sample: Measurement, view_width: f64, zoom: f64) -> bool {
        if !view_width.is_finite() || view_width <= 0. || !(0.09..=1.01).contains(&zoom) {
            return false;
        }
        let expected = view_width / zoom;
        if (sample.viewport - expected).abs() > (expected * 0.03).max(4.)
            || sample.content <= sample.viewport + 2.
        {
            return false;
        }
        if self
            .content_width
            .is_some_and(|old| (old - sample.content).abs() < 1.)
        {
            return false;
        }
        self.content_width = Some(sample.content);
        true
    }

    pub(crate) fn scale(&self, view_width: f64) -> f64 {
        match self.content_width {
            Some(content) if view_width.is_finite() && view_width > 0. => {
                (view_width / content).clamp(MIN_ZOOM, 1.)
            }
            _ => 1.,
        }
    }
}

// Measure only dimensions, never page text or URLs. Coalesce layout changes
// while a page loads or the divider is dragged. Pages control their own CSS;
// the native browser changes zoom only when the document overflows horizontally.
pub(crate) const WIDTH_SCRIPT: &str = r#"
(() => {
  const post = window.ipc?.postMessage?.bind(window.ipc);
  if (!post || window !== window.top) return;
  let timer = 0, last = '', observer;
  const measure = () => {
    timer = 0;
    const root = document.documentElement;
    if (!root) return;
    const viewport = Math.round(window.innerWidth);
    const content = Math.round(Math.max(root.scrollWidth, document.body?.scrollWidth || 0));
    const sample = `${viewport}:${content}`;
    if (sample === last) return;
    last = sample;
    try { post(JSON.stringify({kind:'coincide-page-width-v1', viewport, content})); } catch (_) {}
  };
  const schedule = () => { if (!timer) timer = setTimeout(measure, 100); };
  const observe = () => {
    if (!document.documentElement) return;
    if (!observer && typeof ResizeObserver === 'function') {
      observer = new ResizeObserver(schedule);
      observer.observe(document.documentElement);
    }
    if (observer && document.body) observer.observe(document.body);
    schedule();
  };
  window.addEventListener('resize', schedule, {passive:true});
  window.addEventListener('load', observe, {once:true});
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', observe, {once:true});
  else observe();
})();
"#;

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(viewport: f64, content: f64) -> Measurement {
        Measurement { viewport, content }
    }

    #[test]
    fn responsive_page_stays_at_normal_zoom() {
        let mut fit = PageFit::default();
        assert!(!fit.observe(sample(550., 550.), 550., 1.));
        assert_eq!(fit.scale(550.), 1.);
    }

    #[test]
    fn wide_page_tracks_panel_width_and_recovers_at_full_size() {
        let mut fit = PageFit::default();
        assert!(fit.observe(sample(550., 1000.), 550., 1.));
        assert_eq!(fit.scale(550.), 0.55);
        assert_eq!(fit.scale(750.), 0.75);
        assert!((fit.scale(321.) - 0.321).abs() < 1e-9);
        assert_eq!(fit.scale(1100.), 1.);
        assert_eq!(fit.scale(50.), MIN_ZOOM);
        assert!(fit.observe(sample(1000., 1200.), 550., 0.55));
        assert!((fit.scale(550.) - 550. / 1200.).abs() < 1e-9);
        fit.reset();
        assert_eq!(fit.scale(550.), 1.);
    }

    #[test]
    fn stale_and_invalid_measurements_do_not_change_zoom() {
        let mut fit = PageFit::default();
        assert!(!fit.observe(sample(1000., 1400.), 550., 1.));
        assert!(!fit.observe(sample(550., 1200.), 550., f64::NAN));
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":550,"content":1000}"#)
                .is_some()
        );
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":550,"content":9000000}"#)
                .is_none()
        );
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":"bad","content":1000}"#)
                .is_none()
        );
        assert!(
            measurement(r#"{"kind":"coincide-console-v1","viewport":550,"content":1000}"#)
                .is_none()
        );
    }
}
