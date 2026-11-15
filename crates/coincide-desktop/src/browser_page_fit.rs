//! Fit a page whose document is wider than the browser pane. Responsive pages
//! stay at normal zoom; an agent's explicitly requested viewport takes priority.

use serde_json::Value;
use std::collections::VecDeque;

// The measurement is data, not an allocation. Large documents still fit at
// the bounded minimum zoom instead of remaining hidden until the watchdog.
const MAX_CONTENT_WIDTH: f64 = 1_000_000.;
const MIN_ZOOM: f64 = 0.1;

#[derive(Clone, Debug)]
pub(crate) struct Measurement {
    viewport: f64,
    content: f64,
    document: String,
    held: bool,
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
    let document = value["document"].as_str()?;
    let held = value["held"].as_bool()?;
    if !(40. ..=MAX_CONTENT_WIDTH).contains(&viewport)
        || !(40. ..=MAX_CONTENT_WIDTH).contains(&content)
        || document.is_empty()
        || document.len() > 48
        || !document.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        return None;
    }
    Some(Measurement {
        viewport,
        content,
        document: document.to_owned(),
        held,
    })
}

#[derive(Default)]
pub(crate) struct PageFit {
    content_width: Option<f64>,
    document: Option<String>,
    navigation: u64,
    retired: VecDeque<(String, u64)>,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Update {
    Ignore,
    /// A new document inherited the previous page's zoom. Return it to 100%
    /// while the new document is hidden, then measure its natural width.
    Baseline,
    Ready {
        zoom: Option<f64>,
        reveal: bool,
        changed: bool,
    },
}

impl PageFit {
    pub(crate) fn reset(&mut self) {
        self.content_width = None;
    }

    pub(crate) fn is_new_document(&self, sample: &Measurement) -> bool {
        self.document.as_deref() != Some(sample.document.as_str())
    }

    pub(crate) fn navigation_started(&mut self) {
        self.navigation = self.navigation.wrapping_add(1);
    }

    pub(crate) fn adopt(&mut self, sample: &Measurement) {
        self.reset();
        self.retired
            .retain(|(document, _)| document != &sample.document);
        if let Some(previous) = self.document.replace(sample.document.clone())
            && previous != sample.document
        {
            self.retired.retain(|(document, _)| document != &previous);
            self.retired.push_back((previous, self.navigation));
            if self.retired.len() > 8 {
                self.retired.pop_front();
            }
        }
    }

    /// Only use measurements for the native view's current geometry and zoom.
    pub(crate) fn matches(&self, sample: &Measurement, view_width: f64, zoom: f64) -> bool {
        if !view_width.is_finite() || view_width <= 0. || !(0.09..=1.01).contains(&zoom) {
            return false;
        }
        let expected = view_width / zoom;
        (sample.viewport - expected).abs() <= (expected * 0.03).max(4.)
    }

    pub(crate) fn update(
        &mut self,
        sample: &Measurement,
        view_width: f64,
        zoom: f64,
        fixed_viewport: bool,
    ) -> Update {
        if !self.matches(sample, view_width, zoom)
            || self.retired.iter().any(|(document, navigation)| {
                document == &sample.document && *navigation == self.navigation
            })
        {
            return Update::Ignore;
        }
        let new_document = self.is_new_document(sample);
        if fixed_viewport {
            if new_document {
                self.adopt(sample);
            }
            return Update::Ready {
                zoom: None,
                reveal: sample.held,
                changed: new_document,
            };
        }
        if new_document && (zoom - 1.).abs() > 0.001 {
            self.reset();
            return Update::Baseline;
        }
        if new_document {
            self.adopt(sample);
        }
        let changed = self.observe(sample, view_width, zoom) || new_document;
        Update::Ready {
            zoom: Some(self.scale(view_width)),
            reveal: sample.held,
            changed,
        }
    }

    /// Ignore observations from an old layout, including transient native
    /// screenshot resizes. Zoom changes may produce one-pixel rounding.
    pub(crate) fn observe(&mut self, sample: &Measurement, view_width: f64, zoom: f64) -> bool {
        if !self.matches(sample, view_width, zoom) || sample.content <= sample.viewport + 2. {
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

impl Measurement {
    /// The token is strictly alphanumeric, but still serialize it as JS data.
    pub(crate) fn command(&self, action: &str) -> String {
        debug_assert!(matches!(action, "measure" | "reveal"));
        format!(
            "window.__coincidePageFitV1?.{}({});",
            action,
            serde_json::to_string(&self.document).expect("document token is serializable")
        )
    }

    pub(crate) fn reveal_at(&self, viewport: f64) -> String {
        debug_assert!(viewport.is_finite() && viewport > 0.);
        format!(
            "window.__coincidePageFitV1?.reveal({}, {});",
            serde_json::to_string(&self.document).expect("document token is serializable"),
            viewport
        )
    }
}

// Measure only dimensions, never page text or URLs. Hold the new document's
// visibility until native zoom has been applied, then restore the page's own
// inline value. A deadline prevents a broken bridge from leaving a blank page.
pub(crate) const WIDTH_SCRIPT: &str = r#"
(() => {
  const post = window.ipc?.postMessage?.bind(window.ipc);
  if (!post || window !== window.top) return;
  const token = 'd' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
  let timer = 0, watchdog = 0, revealTimer = 0, expectedViewport, last = '', observer, root, oldValue = '', oldPriority = '', held = false;
  const hold = () => {
    if (held || !document.documentElement || location.href === 'about:blank') return;
    root = document.documentElement;
    oldValue = root.style.getPropertyValue('visibility');
    oldPriority = root.style.getPropertyPriority('visibility');
    root.style.setProperty('visibility', 'hidden', 'important');
    held = true;
    // Never leave a site hidden when its renderer or native bridge stalls.
    watchdog = setTimeout(() => reveal(token), 8000);
  };
  const reveal = (id, expected) => {
    if (id !== token || !held) return;
    // Native zoom is asynchronous on some engines. Do not expose the page
    // until JavaScript sees the viewport that zoom should produce.
    if (Number.isFinite(expected) && Math.abs(window.innerWidth - expected) > Math.max(4, expected * 0.03)) {
      expectedViewport = expected;
      if (!revealTimer) revealTimer = setTimeout(() => {
        revealTimer = 0;
        reveal(id, expectedViewport);
      }, 16);
      return;
    }
    held = false;
    clearTimeout(watchdog);
    clearTimeout(revealTimer);
    revealTimer = 0;
    if (root.style.getPropertyValue('visibility') === 'hidden' &&
        root.style.getPropertyPriority('visibility') === 'important') {
      if (oldValue) root.style.setProperty('visibility', oldValue, oldPriority);
      else root.style.removeProperty('visibility');
    }
    root = null;
  };
  hold();
  if (!root && location.href !== 'about:blank') {
    const rootObserver = new MutationObserver(() => {
      hold();
      if (root) rootObserver.disconnect();
    });
    rootObserver.observe(document, {childList:true});
  }
  const measure = () => {
    timer = 0;
    const element = document.documentElement;
    if (!element) return;
    const viewport = Math.min(1000000, Math.round(window.innerWidth));
    const content = Math.min(1000000, Math.round(Math.max(element.scrollWidth, document.body?.scrollWidth || 0)));
    const sample = `${viewport}:${content}`;
    if (sample === last && !held) return;
    last = sample;
    try { post(JSON.stringify({kind:'coincide-page-width-v1', viewport, content, document:token, held})); } catch (_) {}
    if (held) schedule();
  };
  const schedule = () => { if (!timer) timer = setTimeout(measure, 100); };
  try {
    Object.defineProperty(window, '__coincidePageFitV1', {
      value: {reveal, measure: (id) => { if (id === token) schedule(); }}, configurable: true
    });
  } catch (_) {}
  const observe = () => {
    if (!document.documentElement) return;
    if (!observer && typeof ResizeObserver === 'function') {
      observer = new ResizeObserver(schedule);
      observer.observe(document.documentElement);
    }
    if (observer && document.body) observer.observe(document.body);
    measure();
  };
  window.addEventListener('resize', schedule, {passive:true});
  // Back/forward cache restores the same document without reinjecting scripts.
  window.addEventListener('pagehide', (event) => { if (event.persisted) hold(); });
  window.addEventListener('pageshow', (event) => { if (event.persisted) observe(); });
  window.addEventListener('load', observe, {once:true});
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', observe, {once:true});
  else observe();
})();
"#;

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(viewport: f64, content: f64) -> Measurement {
        Measurement {
            viewport,
            content,
            document: "document1".into(),
            held: true,
        }
    }

    #[test]
    fn responsive_page_stays_at_normal_zoom() {
        let mut fit = PageFit::default();
        assert!(!fit.observe(&sample(550., 550.), 550., 1.));
        assert_eq!(fit.scale(550.), 1.);
    }

    #[test]
    fn wide_page_tracks_panel_width_and_recovers_at_full_size() {
        let mut fit = PageFit::default();
        assert!(fit.observe(&sample(550., 1000.), 550., 1.));
        assert_eq!(fit.scale(550.), 0.55);
        assert_eq!(fit.scale(750.), 0.75);
        assert!((fit.scale(321.) - 0.321).abs() < 1e-9);
        assert_eq!(fit.scale(1100.), 1.);
        assert_eq!(fit.scale(50.), MIN_ZOOM);
        assert!(fit.observe(&sample(1000., 1200.), 550., 0.55));
        assert!((fit.scale(550.) - 550. / 1200.).abs() < 1e-9);
        assert!(fit.observe(&sample(1000., 1_000_000.), 550., 0.55));
        assert_eq!(fit.scale(550.), MIN_ZOOM);
        fit.reset();
        assert_eq!(fit.scale(550.), 1.);
    }

    #[test]
    fn stale_and_invalid_measurements_do_not_change_zoom() {
        let mut fit = PageFit::default();
        assert!(!fit.observe(&sample(1000., 1400.), 550., 1.));
        assert!(!fit.observe(&sample(550., 1200.), 550., f64::NAN));
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":550,"content":1000,"document":"abc123","held":true}"#)
                .is_some()
        );
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":550,"content":9000000,"document":"abc123","held":true}"#)
                .is_none()
        );
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":"bad","content":1000,"document":"abc123","held":true}"#)
                .is_none()
        );
        assert!(
            measurement(r#"{"kind":"coincide-console-v1","viewport":550,"content":1000,"document":"abc123","held":true}"#)
                .is_none()
        );
        assert!(
            measurement(r#"{"kind":"coincide-page-width-v1","viewport":550,"content":1000,"document":"abc\";bad","held":true}"#)
                .is_none()
        );
    }

    #[test]
    fn new_pages_are_fitted_before_they_are_revealed() {
        let mut fit = PageFit::default();
        let first = sample(550., 1000.);
        assert_eq!(
            fit.update(&first, 550., 1., false),
            Update::Ready {
                zoom: Some(0.55),
                reveal: true,
                changed: true
            }
        );
        // Keep the old page at its fitted zoom during the provisional load.
        fit.navigation_started();
        assert_eq!(fit.scale(550.), 0.55);
        let next = Measurement {
            document: "document2".into(),
            ..sample(1000., 1000.)
        };
        assert_eq!(fit.update(&next, 550., 0.55, false), Update::Baseline);
        assert_eq!(fit.scale(550.), 1.);
        // An old-size event cannot reveal the new page after zoom changed.
        assert_eq!(fit.update(&next, 550., 1., false), Update::Ignore);
        let resized = Measurement {
            viewport: 550.,
            content: 550.,
            ..next
        };
        assert_eq!(
            fit.update(&resized, 550., 1., false),
            Update::Ready {
                zoom: Some(1.),
                reveal: true,
                changed: true
            }
        );
    }

    #[test]
    fn fixed_viewports_do_not_get_automatic_zoom() {
        let mut fit = PageFit::default();
        assert_eq!(
            fit.update(&sample(1000., 1400.), 550., 0.55, true),
            Update::Ready {
                zoom: None,
                reveal: true,
                changed: true
            }
        );
    }

    #[test]
    fn late_old_document_is_ignored_but_a_back_navigation_can_restore_it() {
        let mut fit = PageFit::default();
        let first = sample(550., 550.);
        fit.update(&first, 550., 1., false);
        fit.navigation_started();
        let next = Measurement {
            document: "document2".into(),
            ..sample(550., 550.)
        };
        fit.update(&next, 550., 1., false);
        assert_eq!(fit.update(&first, 550., 1., false), Update::Ignore);
        fit.navigation_started();
        assert_eq!(
            fit.update(&first, 550., 1., false),
            Update::Ready {
                zoom: Some(1.),
                reveal: true,
                changed: true
            }
        );
    }

    #[test]
    fn document_tokens_are_serialized_as_data() {
        let sample = sample(550., 1000.);
        assert_eq!(
            sample.command("reveal"),
            "window.__coincidePageFitV1?.reveal(\"document1\");"
        );
        assert_eq!(
            sample.reveal_at(1000.),
            "window.__coincidePageFitV1?.reveal(\"document1\", 1000);"
        );
    }
}
