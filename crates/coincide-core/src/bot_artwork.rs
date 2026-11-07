//! Bot avatars, ported from Swift's `BotArtwork` (CoincideRemoteKit): seven
//! characters laid out on a 100-point grid, top down, with the body in the bot's
//! tint and its outline and shading mixed from it. Small sizes drop the fine
//! details and thicken lines, as in Swift. The result is an SVG document, so every
//! desktop platform draws the same picture through its image renderer.
use std::f64::consts::PI;
use std::fmt::Write as _;

/// The characters, by the names the Mac saves (`BotAvatar.Shape`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Character {
    Alien,
    Star,
    Croissant,
    Bomboloni,
    Cherry,
    Teddy,
    Brulee,
}

/// The body colors, by the names the Mac saves (`BotAvatar.Tint`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tint {
    Sunflower,
    Tangerine,
    Coral,
    Cherry,
    Rose,
    Lilac,
    Sky,
    Mint,
    Leaf,
    Sage,
    Caramel,
}

impl Character {
    pub const ALL: [Self; 7] = [
        Self::Alien,
        Self::Star,
        Self::Croissant,
        Self::Bomboloni,
        Self::Cherry,
        Self::Teddy,
        Self::Brulee,
    ];
    pub fn raw(self) -> &'static str {
        match self {
            Self::Alien => "alien",
            Self::Star => "star",
            Self::Croissant => "croissant",
            Self::Bomboloni => "bomboloni",
            Self::Cherry => "cherry",
            Self::Teddy => "teddy",
            Self::Brulee => "brulee",
        }
    }
    /// A saved name, including the plain body shapes of earlier versions, which
    /// read as the character closest in silhouette.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|character| character.raw() == raw)
            .or(match raw {
                "blob" => Some(Self::Alien),
                "pebble" => Some(Self::Croissant),
                "cloud" => Some(Self::Teddy),
                "drop" => Some(Self::Brulee),
                "bean" | "sprout" => Some(Self::Cherry),
                "bun" => Some(Self::Bomboloni),
                _ => None,
            })
    }
    /// The color the character was drawn in, which it starts with.
    pub fn default_tint(self) -> Tint {
        match self {
            Self::Alien => Tint::Leaf,
            Self::Star | Self::Bomboloni => Tint::Sunflower,
            Self::Croissant => Tint::Tangerine,
            Self::Cherry => Tint::Cherry,
            Self::Teddy => Tint::Caramel,
            Self::Brulee => Tint::Rose,
        }
    }
    /// A proper name in plain ASCII, the same in every language.
    pub fn default_name(self) -> &'static str {
        match self {
            Self::Alien => "Alien",
            Self::Star => "Star",
            Self::Croissant => "Croissant",
            Self::Bomboloni => "Bomboloni",
            Self::Cherry => "Cherry",
            Self::Teddy => "Teddy",
            Self::Brulee => "Brulee",
        }
    }
    /// The personality preset a new bot with this character is offered.
    pub fn default_personality(self) -> Option<&'static str> {
        crate::bot_personality::default_for_character(self.raw())
    }
}

impl Tint {
    pub const ALL: [Self; 11] = [
        Self::Sunflower,
        Self::Tangerine,
        Self::Coral,
        Self::Cherry,
        Self::Rose,
        Self::Lilac,
        Self::Sky,
        Self::Mint,
        Self::Leaf,
        Self::Sage,
        Self::Caramel,
    ];
    pub fn raw(self) -> &'static str {
        match self {
            Self::Sunflower => "sunflower",
            Self::Tangerine => "tangerine",
            Self::Coral => "coral",
            Self::Cherry => "cherry",
            Self::Rose => "rose",
            Self::Lilac => "lilac",
            Self::Sky => "sky",
            Self::Mint => "mint",
            Self::Leaf => "leaf",
            Self::Sage => "sage",
            Self::Caramel => "caramel",
        }
    }
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|tint| tint.raw() == raw)
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Sunflower => "Sunflower",
            Self::Tangerine => "Tangerine",
            Self::Coral => "Coral",
            Self::Cherry => "Cherry",
            Self::Rose => "Rose",
            Self::Lilac => "Lilac",
            Self::Sky => "Sky",
            Self::Mint => "Mint",
            Self::Leaf => "Leaf",
            Self::Sage => "Sage",
            Self::Caramel => "Caramel",
        }
    }
    /// The body color, 0xRRGGBB, the same in light and dark themes.
    pub fn rgb(self) -> u32 {
        match self {
            Self::Sunflower => 0xF5C542,
            Self::Tangerine => 0xF7A24B,
            Self::Coral => 0xF2786A,
            Self::Cherry => 0xD9534F,
            Self::Rose => 0xEE7FAA,
            Self::Lilac => 0xA98AEF,
            Self::Sky => 0x63AEF2,
            Self::Mint => 0x4FCBA2,
            Self::Leaf => 0x74C163,
            Self::Sage => 0x93B874,
            Self::Caramel => 0xD9A063,
        }
    }
}

/// The avatar as an SVG document `pixels` wide and tall, drawn for `side` points
/// on screen (which decides its detail). `openness` is how far the eyes are open,
/// 1 fully and near 0 mid-blink.
pub fn svg(character: Character, tint: Tint, side: f64, pixels: u32, openness: f64) -> String {
    let side = side.max(1.);
    let mut pen = Pen {
        out: String::new(),
        scale: side / 100.,
        detail: Detail::new(side),
        body: Color::hex(tint.rgb()),
        open: openness.clamp(0.1, 1.),
        clips: 0,
    };
    match character {
        Character::Alien => alien(&mut pen),
        Character::Star => star(&mut pen),
        Character::Croissant => croissant(&mut pen),
        Character::Bomboloni => bomboloni(&mut pen),
        Character::Cherry => cherry(&mut pen),
        Character::Teddy => teddy(&mut pen),
        Character::Brulee => brulee(&mut pen),
    }
    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{pixels}\" height=\"{pixels}\" viewBox=\"0 0 100 100\">{}</svg>",
        pen.out
    )
}

// MARK: Drawing primitives

#[derive(Clone, Copy, Debug, PartialEq)]
struct Color {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
}
impl Color {
    fn hex(hex: u32) -> Self {
        Self {
            r: ((hex >> 16) & 0xFF) as f64 / 255.,
            g: ((hex >> 8) & 0xFF) as f64 / 255.,
            b: (hex & 0xFF) as f64 / 255.,
            a: 1.,
        }
    }
    const WHITE: Self = Self {
        r: 1.,
        g: 1.,
        b: 1.,
        a: 1.,
    };
    const BLACK: Self = Self {
        r: 0.,
        g: 0.,
        b: 0.,
        a: 1.,
    };
    fn alpha(self, a: f64) -> Self {
        Self { a, ..self }
    }
    /// `fraction` of the way to `other`, component by component.
    fn blended(self, fraction: f64, other: Self) -> Self {
        Self {
            r: self.r + (other.r - self.r) * fraction,
            g: self.g + (other.g - self.g) * fraction,
            b: self.b + (other.b - self.b) * fraction,
            a: self.a + (other.a - self.a) * fraction,
        }
    }
    fn paint(self, attribute: &str) -> String {
        let byte = |v: f64| (v.clamp(0., 1.) * 255.).round() as u8;
        let mut text = format!(
            "{attribute}=\"#{:02x}{:02x}{:02x}\"",
            byte(self.r),
            byte(self.g),
            byte(self.b)
        );
        if self.a < 1. {
            let _ = write!(text, " {attribute}-opacity=\"{}\"", number(self.a));
        }
        text
    }
}
const INK: u32 = 0x231E21;
fn rgb(hex: u32) -> Color {
    Color::hex(hex)
}
fn darker(color: Color, fraction: f64) -> Color {
    color.blended(fraction, Color::BLACK)
}
fn lighter(color: Color, fraction: f64) -> Color {
    color.blended(fraction, Color::WHITE)
}
/// `preferred` where it stands out on `body`, otherwise dark ink, so a feature
/// never vanishes into a recolored body.
fn readable(preferred: Color, body: Color) -> Color {
    fn luminance(color: Color) -> f64 {
        let linear = |v: f64| {
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }
    let (a, b) = (luminance(preferred), luminance(body));
    if (a.max(b) + 0.05) / (a.min(b) + 0.05) >= 2.4 {
        preferred
    } else {
        rgb(INK)
    }
}

/// Three decimals at most, without trailing zeros, for compact deterministic output.
fn number(value: f64) -> String {
    let rounded = (value * 1000.).round() / 1000.;
    let mut text = format!("{rounded:.3}");
    while text.ends_with('0') {
        text.pop();
    }
    if text.ends_with('.') {
        text.pop();
    }
    if text == "-0" { "0".into() } else { text }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Detail {
    Tiny,
    Small,
    Full,
}
impl Detail {
    /// Everything from 34 points, faces without the fine details below that, and
    /// only the shapes that still read below 20.
    fn new(side: f64) -> Self {
        if side < 20. {
            Self::Tiny
        } else if side < 34. {
            Self::Small
        } else {
            Self::Full
        }
    }
}

type Point = (f64, f64);

/// A shape to fill, stroke or clip to.
#[derive(Clone)]
enum Shape {
    Path(String),
    Ellipse {
        center: Point,
        rx: f64,
        ry: f64,
        rotation: f64,
    },
    Rect {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        radius: f64,
    },
    /// A shape drawn through an SVG transform, such as the watercolor bleed.
    Transformed(Box<Shape>, String),
}
impl Shape {
    fn element(&self, paint: &str) -> String {
        match self {
            Self::Path(d) => format!("<path d=\"{d}\" {paint}/>"),
            Self::Ellipse {
                center,
                rx,
                ry,
                rotation,
            } => {
                let rotate = if *rotation == 0. {
                    String::new()
                } else {
                    format!(
                        " transform=\"rotate({} {} {})\"",
                        number(*rotation),
                        number(center.0),
                        number(center.1)
                    )
                };
                format!(
                    "<ellipse cx=\"{}\" cy=\"{}\" rx=\"{}\" ry=\"{}\"{rotate} {paint}/>",
                    number(center.0),
                    number(center.1),
                    number(*rx),
                    number(*ry)
                )
            }
            Self::Rect {
                x,
                y,
                width,
                height,
                radius,
            } => {
                let corner = if *radius > 0. {
                    format!(" rx=\"{0}\" ry=\"{0}\"", number(*radius))
                } else {
                    String::new()
                };
                format!(
                    "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\"{corner} {paint}/>",
                    number(*x),
                    number(*y),
                    number(*width),
                    number(*height)
                )
            }
            Self::Transformed(shape, transform) => {
                format!("<g transform=\"{transform}\">{}</g>", shape.element(paint))
            }
        }
    }
}

/// Path data, written with the same calls as Swift's CGMutablePath.
#[derive(Default)]
struct Path(String);
impl Path {
    fn command(&mut self, letter: char, points: &[f64]) -> &mut Self {
        if !self.0.is_empty() {
            self.0.push(' ');
        }
        self.0.push(letter);
        for (index, value) in points.iter().enumerate() {
            if index > 0 {
                self.0.push(' ');
            }
            self.0.push_str(&number(*value));
        }
        self
    }
    fn move_to(&mut self, p: Point) -> &mut Self {
        self.command('M', &[p.0, p.1])
    }
    fn line(&mut self, p: Point) -> &mut Self {
        self.command('L', &[p.0, p.1])
    }
    fn quad(&mut self, to: Point, control: Point) -> &mut Self {
        self.command('Q', &[control.0, control.1, to.0, to.1])
    }
    /// A cubic curve, written as the control points and end point's coordinates.
    fn curve(&mut self, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) -> &mut Self {
        self.command('C', &[c1x, c1y, c2x, c2y, x, y])
    }
    fn close(&mut self) -> &mut Self {
        self.command('Z', &[])
    }
    fn shape(&self) -> Shape {
        Shape::Path(self.0.clone())
    }
}
fn path(build: impl FnOnce(&mut Path)) -> Shape {
    let mut path = Path::default();
    build(&mut path);
    path.shape()
}
fn ellipse(center: Point, rx: f64, ry: f64) -> Shape {
    rotated_ellipse(center, rx, ry, 0.)
}
fn rotated_ellipse(center: Point, rx: f64, ry: f64, rotation: f64) -> Shape {
    Shape::Ellipse {
        center,
        rx,
        ry,
        rotation,
    }
}
fn rotate(point: Point, center: Point, degrees: f64) -> Point {
    let angle = degrees * PI / 180.;
    let (dx, dy) = (point.0 - center.0, point.1 - center.1);
    (
        center.0 + dx * angle.cos() - dy * angle.sin(),
        center.1 + dx * angle.sin() + dy * angle.cos(),
    )
}
/// A closed polygon whose corners are rounded: each corner's curve starts
/// `roundness(index)` of the way along its two edges.
fn rounded_polygon(points: &[Point], roundness: impl Fn(usize) -> f64) -> Shape {
    let toward = |from: Point, to: Point, fraction: f64| {
        (
            from.0 + (to.0 - from.0) * fraction,
            from.1 + (to.1 - from.1) * fraction,
        )
    };
    let count = points.len();
    let mut path = Path::default();
    for index in 0..count {
        let corner = points[index];
        let previous = points[(index + count - 1) % count];
        let next = points[(index + 1) % count];
        let fraction = roundness(index);
        let start = toward(corner, previous, fraction);
        let end = toward(corner, next, fraction);
        if index == 0 {
            path.move_to(start);
        } else {
            path.line(start);
        }
        path.quad(end, corner);
    }
    path.close();
    path.shape()
}
/// An Archimedean spiral winding out from `center`, flattened vertically by `squash`.
fn spiral(center: Point, radius: f64, turns: f64, squash: f64) -> Shape {
    let steps = (turns * 36.) as usize;
    let mut path = Path::default();
    for step in 0..=steps {
        let t = step as f64 / steps as f64;
        let angle = t * turns * 2. * PI;
        let r = radius * t;
        let point = (
            center.0 + r * angle.cos(),
            center.1 + r * angle.sin() * squash,
        );
        if step == 0 {
            path.move_to(point);
        } else {
            path.line(point);
        }
    }
    path.shape()
}
/// The watercolor bleed: the shape nudged and grown a little around `anchor`.
fn bleed(shape: Shape, nudge: Point, anchor: Point, scale: f64) -> Shape {
    Shape::Transformed(
        Box::new(shape),
        format!(
            "translate({} {}) translate({} {}) scale({}) translate({} {})",
            number(nudge.0),
            number(nudge.1),
            number(anchor.0),
            number(anchor.1),
            number(scale),
            number(-anchor.0),
            number(-anchor.1)
        ),
    )
}

/// What one avatar is drawn with: how much detail its size allows, the body
/// color and how far the eyes are open.
struct Pen {
    out: String,
    scale: f64,
    detail: Detail,
    body: Color,
    open: f64,
    clips: usize,
}
impl Pen {
    fn fill(&mut self, shape: &Shape, color: Color) {
        self.out.push_str(&shape.element(&color.paint("fill")));
    }
    /// A line `units` grid points wide, never thinner than `minimum` points on screen.
    fn stroke(&mut self, shape: &Shape, color: Color, units: f64, minimum: f64) {
        let width = units.max(minimum / self.scale);
        let paint = format!(
            "fill=\"none\" {} stroke-width=\"{}\" stroke-linecap=\"round\" stroke-linejoin=\"round\"",
            color.paint("stroke"),
            number(width)
        );
        self.out.push_str(&shape.element(&paint));
    }
    /// The body's own edge, a shade darker, so pale colors hold their shape.
    fn edge(&mut self, shape: &Shape, soft: bool) {
        let color = darker(self.body, if soft { 0.2 } else { 0.38 });
        self.stroke(shape, color, if soft { 1.5 } else { 2.4 }, 0.7);
    }
    /// Draws `draw` clipped to `shape`.
    fn clipped(&mut self, shape: &Shape, draw: impl FnOnce(&mut Self)) {
        self.clips += 1;
        let id = format!("clip{}", self.clips);
        let _ = write!(
            self.out,
            "<clipPath id=\"{id}\">{}</clipPath><g clip-path=\"url(#{id})\">",
            shape.element("")
        );
        draw(self);
        self.out.push_str("</g>");
    }
}

/// A small five-point sparkle, grey with a paler middle, as in the alien's eyes.
fn sparkle(pen: &mut Pen, center: Point, radius: f64) {
    let points = (0..10)
        .map(|index| {
            let r = if index % 2 == 0 { radius } else { radius * 0.5 };
            let angle = index as f64 * PI / 5. - PI / 2. + 0.2;
            (center.0 + r * angle.cos(), center.1 + r * angle.sin())
        })
        .collect::<Vec<_>>();
    pen.fill(&rounded_polygon(&points, |_| 0.3), rgb(0xA9A8A4));
    pen.fill(&ellipse(center, radius * 0.34, radius * 0.3), rgb(0xD9D8D4));
}

// MARK: Characters

/// A round green head with eyes on stalks, big starry eyes, pink cheeks and a
/// blue tongue poking out.
fn alien(pen: &mut Pen) {
    let head = path(|p| {
        p.move_to((52., 26.))
            .curve(73., 25., 88., 40., 87., 59.)
            .curve(86., 78., 71., 90., 51., 90.)
            .curve(31., 89., 16., 77., 16., 58.)
            .curve(16., 39., 31., 27., 52., 26.);
    });
    // Stalks and their eyes first, so the head covers where they join.
    for (start, control, end) in [
        ((37., 33.), (26., 22.), (17., 25.)),
        ((64., 31.), (72., 18.), (80., 15.)),
    ] {
        let line = path(|p| {
            p.move_to(start).quad(end, control);
        });
        let body = pen.body;
        pen.stroke(&line, body, 3.6, 1.1);
    }
    for (center, angle) in [((15., 25.), -12.), ((82., 14.), -18.)] {
        let ball = rotated_ellipse(center, 11.5, 8., angle);
        let body = pen.body;
        pen.fill(&ball, body);
        pen.edge(&ball, true);
        let pupil = rotated_ellipse(
            (center.0 + if center.0 < 50. { -2. } else { 2. }, center.1),
            5.,
            3.6 * pen.open,
            angle,
        );
        pen.fill(&pupil, rgb(INK));
    }
    // The tongue sits behind the chin, under the head's edge.
    let tongue = path(|p| {
        p.move_to((44.5, 84.))
            .curve(44., 100., 60., 100., 59.5, 84.)
            .close();
    });
    pen.fill(&tongue, rgb(0x4A6FBF));
    if pen.detail > Detail::Tiny {
        pen.stroke(&tongue, rgb(0x1D2442), 1.5, 0.6);
        let groove = path(|p| {
            p.move_to((52., 90.)).line((52., 95.));
        });
        pen.stroke(&groove, rgb(0x1D2442), 1.5, 0.6);
    }
    let body = pen.body;
    pen.fill(&head, body);
    pen.edge(&head, true);

    // Big almond eyes hugging the sides of the head, leaning in at the top.
    let eyes = [((30.5, 58.), 13.), ((72.5, 54.5), -13.)];
    pen.clipped(&head, |pen| {
        for (center, angle) in eyes {
            let eye = rotated_ellipse(center, 12.8, 20. * pen.open, angle);
            pen.fill(&eye, rgb(INK));
        }
    });
    if pen.open > 0.6 {
        for (center, angle) in eyes {
            let side = if center.0 < 50. { 1. } else { -1. };
            if pen.detail == Detail::Full {
                sparkle(
                    pen,
                    rotate((center.0 + 1., center.1 - 7.5), center, angle),
                    5.2,
                );
                sparkle(
                    pen,
                    rotate((center.0 - 2. * side, center.1 + 6.5), center, angle),
                    4.6,
                );
                pen.fill(
                    &ellipse(
                        rotate((center.0 + 4.5 * side, center.1 + 1.), center, angle),
                        2.4,
                        1.6,
                    ),
                    Color::WHITE,
                );
            } else if pen.detail == Detail::Small {
                pen.fill(
                    &ellipse(
                        rotate((center.0 + 1., center.1 - 6.), center, angle),
                        3.4,
                        3.4,
                    ),
                    rgb(0xD8D7D3),
                );
            }
        }
    }
    if pen.detail > Detail::Tiny {
        pen.fill(&rotated_ellipse((40.5, 78.), 5.2, 2.8, 20.), rgb(0xF4A9D2));
        pen.fill(
            &rotated_ellipse((64.5, 74.5), 5.2, 2.8, -10.),
            rgb(0xF4A9D2),
        );
    }
}

/// A chubby golden star with brown eyes, peachy blush and a puckered kiss.
fn star(pen: &mut Pen) {
    // Five slightly uneven arms, the whole star tipped a little to the left.
    let center = (50., 55.);
    let outer = [47., 46., 47.5, 45.5, 46.5];
    let vertices = (0..10)
        .map(|index| {
            let radius = if index % 2 == 0 {
                outer[index / 2]
            } else {
                23.
            };
            let angle = -PI / 2. + index as f64 * PI / 5. - 0.12;
            (
                center.0 + radius * angle.cos(),
                center.1 + radius * angle.sin(),
            )
        })
        .collect::<Vec<_>>();
    let shape = rounded_polygon(&vertices, |index| if index % 2 == 0 { 0.2 } else { 0.32 });
    let body = pen.body;
    pen.fill(&shape, body);
    pen.edge(&shape, true);

    let brown = readable(rgb(0x8A4519), pen.body);
    for x in [41.5, 59.] {
        let eye = rotated_ellipse((x, 47.), 4.8, 8. * pen.open, if x < 50. { 6. } else { -6. });
        pen.fill(&eye, brown);
        if pen.detail == Detail::Full && pen.open > 0.6 {
            pen.fill(&ellipse((x - 1.4, 44.), 1.7, 2.1), Color::WHITE.alpha(0.85));
        }
    }
    if pen.detail > Detail::Tiny {
        pen.fill(&ellipse((34.5, 58.), 5.4, 3.), rgb(0xFA9C9C).alpha(0.85));
        pen.fill(&ellipse((66., 58.), 5.4, 3.), rgb(0xFA9C9C).alpha(0.85));
    }
    let red = rgb(0xE5443B);
    if pen.detail == Detail::Tiny {
        pen.fill(&ellipse((51., 63.), 2.6, 2.6), red);
    } else {
        let kiss = path(|p| {
            p.move_to((53.5, 58.8))
                .curve(49.4, 58., 48.8, 62.2, 51.8, 62.7)
                .curve(48.6, 63.4, 49.4, 67.8, 53.6, 66.8);
        });
        pen.stroke(&kiss, red, 2.4, 0.9);
    }
}

/// A flat orange croissant of a cat: pastry ridges, sparkly eyes close together,
/// whiskers and a little frown.
fn croissant(pen: &mut Pen) {
    let loaf = path(|p| {
        p.move_to((13., 47.))
            .curve(18., 34., 32., 30., 43., 33.)
            .curve(51., 28., 63., 28., 71., 33.)
            .curve(83., 30., 95., 39., 94., 51.)
            .curve(97., 60., 95., 71., 87., 74.)
            .curve(78., 81., 61., 80., 50., 79.)
            .curve(35., 81., 17., 81., 9., 73.)
            .curve(3., 67., 4., 55., 13., 47.);
    });
    let body = pen.body;
    pen.fill(&loaf, body);
    pen.stroke(&loaf, darker(body, 0.18), 2.8, 0.9);

    let ridge = darker(body, 0.42);
    let ridges: &[(Point, Point, Point)] = if pen.detail == Detail::Tiny {
        &[
            ((38., 37.), (33., 43.), (36., 50.)),
            ((62., 36.), (67., 42.), (64., 49.)),
        ]
    } else {
        &[
            ((33., 37.), (28.5, 43.), (31., 51.)),
            ((45., 34.), (42., 39.5), (44., 46.)),
            ((57., 34.), (60., 39.5), (58.5, 46.)),
            ((70., 37.), (74.5, 43.), (72., 50.)),
        ]
    };
    for &(start, control, end) in ridges {
        let line = path(|p| {
            p.move_to(start).quad(end, control);
        });
        pen.stroke(&line, ridge, 2.4, 0.8);
    }
    if pen.detail == Detail::Full {
        for (y, tilt) in [(58., -2.), (62.5, 0.), (67., 2.)] {
            for (inner, outer) in [(30., 20.), (71., 81.)] {
                let whisker = path(|p| {
                    p.move_to((inner, y))
                        .line((outer, y + (if outer < inner { tilt } else { -tilt }) * 1.2));
                });
                pen.stroke(&whisker, ridge, 1.4, 0.6);
            }
        }
    }

    let radius = if pen.detail == Detail::Tiny { 7.5 } else { 6.6 };
    for x in [42.5, 59.5] {
        pen.fill(&ellipse((x, 59.), radius, radius * pen.open), rgb(INK));
        if pen.open <= 0.6 {
            continue;
        }
        if pen.detail == Detail::Full {
            pen.fill(&ellipse((x - 2.2, 56.4), 2.6, 2.6), Color::WHITE);
            pen.fill(&ellipse((x + 2.6, 62.), 1.3, 1.3), Color::WHITE);
        } else if pen.detail == Detail::Small {
            pen.fill(&ellipse((x - 2., 56.6), 2., 2.), Color::WHITE);
        }
    }
    if pen.detail == Detail::Full {
        let red = rgb(0xE5533F).alpha(0.85);
        for x in [35., 38.4, 63.6, 67.] {
            let dash = path(|p| {
                p.move_to((x + 1.2, 66.)).line((x - 1.2, 69.));
            });
            pen.stroke(&dash, red, 1.3, 0.6);
        }
    } else if pen.detail == Detail::Small {
        pen.fill(&ellipse((35.5, 67.), 3.6, 2.), rgb(0xFF6F7F).alpha(0.7));
        pen.fill(&ellipse((66.5, 67.), 3.6, 2.), rgb(0xFF6F7F).alpha(0.7));
    }
    if pen.detail > Detail::Tiny {
        let frown = path(|p| {
            p.move_to((48.5, 70.)).quad((53.5, 70.), (51., 67.6));
        });
        pen.stroke(&frown, darker(body, 0.6), 1.5, 0.7);
    }
}

/// A wobbly pudding with a caramel top and a cherry, floppy pup ears, round black
/// eyes and red cheeks.
fn bomboloni(pen: &mut Pen) {
    let body = pen.body;
    let outline = darker(body, 0.3);
    let pudding = rounded_polygon(
        &[(27., 24.), (73.5, 23.5), (90.5, 84.), (10., 84.5)],
        |_| 0.08,
    );
    pen.fill(&pudding, lighter(body, 0.55));

    // The caramel pools on top and drips down the sides, kept inside the pudding.
    pen.clipped(&pudding, |pen| {
        let caramel = rgb(0x9C5A16);
        pen.fill(
            &Shape::Rect {
                x: 0.,
                y: 0.,
                width: 100.,
                height: 33.,
                radius: 0.,
            },
            caramel,
        );
        for (x, width, bottom) in [
            (33., 7., 42.),
            (48.5, 8.5, 46.5),
            (63., 7., 41.),
            (76., 6., 37.),
        ] {
            pen.fill(
                &Shape::Rect {
                    x: x - width / 2.,
                    y: 28.,
                    width,
                    height: bottom - 28.,
                    radius: width / 2.,
                },
                caramel,
            );
        }
    });
    pen.stroke(&pudding, outline, 2.4, 0.8);
    for side in [-1., 1.] {
        let ear = path(|p| {
            p.move_to((50. + 13. * side, 25.))
                .curve(
                    50. + 24. * side,
                    15.,
                    50. + 43. * side,
                    16.,
                    50. + 48. * side,
                    27.,
                )
                .curve(
                    50. + 52. * side,
                    36.,
                    50. + 47. * side,
                    45.,
                    50. + 39. * side,
                    43.,
                )
                .curve(
                    50. + 31. * side,
                    41.,
                    50. + 25. * side,
                    34.,
                    50. + 19. * side,
                    31.,
                )
                .curve(
                    50. + 14. * side,
                    29.,
                    50. + 11. * side,
                    28.,
                    50. + 13. * side,
                    25.,
                );
        });
        pen.fill(&ear, body);
        pen.stroke(&ear, outline, 2.2, 0.7);
    }

    let stem = path(|p| {
        p.move_to((67.5, 11.5)).quad((77., 3.5), (69.5, 4.5));
    });
    pen.stroke(&stem, rgb(0x3F7D2E), 2., 0.7);
    pen.fill(&ellipse((66., 17.), 6.6, 6.2), rgb(0xC8302B));
    if pen.detail == Detail::Full {
        pen.fill(&ellipse((63.6, 15.), 1.7, 1.4), Color::WHITE.alpha(0.8));
    }

    let radius = if pen.detail == Detail::Tiny { 7.4 } else { 6.8 };
    for x in [37., 63.] {
        pen.fill(&ellipse((x, 58.), radius, radius * pen.open), rgb(INK));
        if pen.detail > Detail::Tiny && pen.open > 0.6 {
            pen.fill(&ellipse((x - 2.3, 55.4), 2.1, 2.1), Color::WHITE);
        }
    }
    if pen.detail > Detail::Tiny {
        pen.fill(&ellipse((27.5, 65.5), 5., 3.), rgb(0xF2453D).alpha(0.85));
        pen.fill(&ellipse((72.5, 65.5), 5., 3.), rgb(0xF2453D).alpha(0.85));
        let mouth = path(|p| {
            p.move_to((47.4, 65.))
                .quad((50., 66.6), (48.4, 67.))
                .quad((52.6, 65.), (51.6, 67.));
        });
        pen.stroke(&mouth, rgb(0x7A4A20), 1.4, 0.6);
    }
}

/// A plump cherry on a hooked stem, with dizzy spiral eyes, red cheeks and a
/// wobbly frown.
fn cherry(pen: &mut Pen) {
    let body = pen.body;
    let fruit = path(|p| {
        p.move_to((51., 34.))
            .curve(43., 23., 26., 23., 18., 33.)
            .curve(8., 44., 9., 64., 20., 77.)
            .curve(30., 89., 44., 91., 51., 89.)
            .curve(58., 91., 72., 89., 81., 77.)
            .curve(92., 64., 92., 44., 83., 33.)
            .curve(74., 23., 59., 23., 51., 34.);
    });
    if pen.detail > Detail::Tiny {
        // The color bleeds a little past the outline, as the watercolor fill does.
        let wash = bleed(fruit.clone(), (-2.4, 1.6), (50., 58.), 1.04);
        pen.fill(&wash, lighter(body, 0.35).alpha(0.75));
    }
    let green = readable(rgb(0x2A6B2E), body);
    let stem = path(|p| {
        p.move_to((51., 34.)).curve(50., 24., 53., 13., 64., 8.);
    });
    pen.stroke(&stem, rgb(0x2A6B2E), 3., 0.9);
    if pen.detail == Detail::Full {
        pen.fill(&rotated_ellipse((56., 16.), 4.2, 2.2, -40.), rgb(0x5FA347));
    }
    pen.fill(&fruit, body);
    pen.stroke(&fruit, darker(body, 0.32), 3., 0.9);

    let turns = match pen.detail {
        Detail::Full => 2.25,
        Detail::Small => 1.75,
        Detail::Tiny => 1.25,
    };
    let width = if pen.detail == Detail::Full { 2. } else { 2.8 };
    for x in [36., 65.] {
        let eye = spiral((x, 55.), 9.5, turns, pen.open);
        pen.stroke(&eye, green, width, 0.8);
    }
    if pen.detail > Detail::Tiny {
        pen.fill(&ellipse((23.5, 67.), 5.6, 3.), rgb(0xE6463C).alpha(0.9));
        pen.fill(&ellipse((77.5, 67.), 5.6, 3.), rgb(0xE6463C).alpha(0.9));
    }
    let frown = path(|p| {
        p.move_to((44., 74.5))
            .curve(45., 68.5, 56., 68.5, 57., 74.5)
            .curve(54., 72.6, 47., 72.6, 44., 74.5);
    });
    pen.fill(&frown, green);
    pen.stroke(&frown, green, 1., 0.5);
}

/// A round teddy face with ears, shiny black eyes, pink blush and a soft muzzle.
fn teddy(pen: &mut Pen) {
    let body = pen.body;
    let outline = darker(body, 0.42);
    for x in [22., 78.] {
        let ear = ellipse((x, 26.), 14., 13.5);
        pen.fill(&ear, body);
        pen.stroke(&ear, outline, 2.4, 0.8);
        if pen.detail > Detail::Tiny {
            pen.fill(
                &ellipse((x + if x < 50. { 1. } else { -1. }, 27.5), 7.5, 7.),
                darker(body, 0.24),
            );
        }
    }
    let face = path(|p| {
        p.move_to((50., 23.))
            .curve(73., 22., 90., 37., 89., 57.)
            .curve(88., 78., 71., 92., 50., 92.)
            .curve(28., 92., 11., 79., 11., 57.)
            .curve(11., 37., 27., 24., 50., 23.);
    });
    if pen.detail > Detail::Tiny {
        let wash = bleed(face.clone(), (-2., 1.8), (50., 57.), 1.035);
        pen.fill(&wash, lighter(body, 0.3).alpha(0.8));
    }
    pen.fill(&face, body);
    pen.stroke(&face, outline, 2.6, 0.9);

    for x in [37., 63.] {
        pen.fill(&ellipse((x, 51.), 5.4, 6.8 * pen.open), rgb(INK));
        if pen.detail > Detail::Tiny && pen.open > 0.6 {
            pen.fill(&ellipse((x - 1.6, 48.6), 2.1, 2.1), Color::WHITE);
        }
    }
    if pen.detail > Detail::Tiny {
        pen.fill(&ellipse((27.5, 61.), 5., 2.8), rgb(0xF79AC4).alpha(0.85));
        pen.fill(&ellipse((72.5, 61.), 5., 2.8), rgb(0xF79AC4).alpha(0.85));
    }
    pen.fill(&ellipse((50., 70.), 14., 10.5), darker(body, 0.16));
    pen.fill(&ellipse((50., 67.), 7.5, 4.6), darker(body, 0.45));
}

/// A girl with a blocky bob in the bot's color, sleepy blue eyes, a tongue poking
/// out and an ice cream melting on her head.
fn brulee(pen: &mut Pen) {
    let body = pen.body;
    let line = rgb(0x2E2428);
    let hair = path(|p| {
        p.move_to((17., 34.))
            .line((83.5, 33.))
            .line((84., 95.))
            .line((59., 95.5))
            .line((59., 86.))
            .line((41., 86.))
            .line((41., 96.))
            .line((16.5, 96.))
            .close();
    });
    pen.fill(&hair, body);
    pen.stroke(&hair, line, 1.5, 0.6);
    let face = Shape::Rect {
        x: 28.,
        y: 44.,
        width: 44.,
        height: 42.,
        radius: 0.,
    };
    pen.fill(&face, rgb(0xF8DDB4));
    let bangs = path(|p| {
        p.move_to((27.5, 43.))
            .line((72.5, 43.))
            .line((72.5, 56.))
            .line((64., 56.))
            .line((64., 50.))
            .line((57., 50.))
            .line((57., 54.))
            .line((46., 54.))
            .line((46., 49.))
            .line((40., 49.))
            .line((40., 58.))
            .line((27.5, 58.))
            .close();
    });
    pen.fill(&bangs, body);
    if pen.detail > Detail::Tiny {
        pen.stroke(&bangs, line, 1.2, 0.5);
    }
    if pen.detail == Detail::Full {
        // A few strands in a deeper shade, and a shine across the top.
        let strand = darker(body, 0.25);
        for (a, b, c) in [
            ((22., 88.), (25., 92.), (31., 85.)),
            ((66., 90.), (69., 93.), (75., 86.)),
            ((76., 40.), (79., 44.), (81., 37.)),
            ((20., 46.), (23., 50.), (25., 44.)),
        ] {
            let tick = path(|p| {
                p.move_to(a).line(b).line(c);
            });
            pen.stroke(&tick, strand, 1.3, 0.5);
        }
        pen.fill(
            &rotated_ellipse((47., 38.5), 10., 2.4, -3.),
            lighter(body, 0.45),
        );
    }

    // Half-shut blue eyes under heavy lids.
    for x in [39.5, 60.5] {
        if pen.open > 0.25 {
            let open = pen.open;
            let iris = path(|p| {
                p.move_to((x - 5.4, 66.5))
                    .curve(
                        x - 5.,
                        66.5 + 7. * open,
                        x + 5.,
                        66.5 + 7. * open,
                        x + 5.4,
                        66.5,
                    )
                    .close();
            });
            pen.fill(&iris, rgb(0x4FB0E6));
            if pen.detail == Detail::Full {
                pen.fill(
                    &ellipse((x + 0.5, 68.6), 1.6, 1.2),
                    Color::WHITE.alpha(0.85),
                );
            }
        }
        let lid = path(|p| {
            p.move_to((x - 6.2, 66.8)).quad((x + 6.2, 66.8), (x, 64.6));
        });
        pen.stroke(&lid, line, 1.6, 0.7);
        if pen.detail == Detail::Full {
            let outward = if x < 50. { -1. } else { 1. };
            for (dx, dy) in [(5.6, -1.4), (3.8, -2.6)] {
                let lash = path(|p| {
                    p.move_to((x + dx * outward, 66. + dy * 0.4))
                        .line((x + (dx + 1.8) * outward, 66. + dy));
                });
                pen.stroke(&lash, line, 1., 0.4);
            }
        }
    }
    if pen.detail > Detail::Tiny {
        pen.fill(&ellipse((34.5, 74.5), 4.4, 2.1), rgb(0xF48FA6).alpha(0.75));
        pen.fill(&ellipse((65.5, 74.5), 4.4, 2.1), rgb(0xF48FA6).alpha(0.75));
        let mouth = path(|p| {
            p.move_to((48.2, 77.)).quad((51.8, 77.), (50., 78.2));
        });
        pen.stroke(&mouth, line, 1., 0.5);
    }
    pen.fill(&ellipse((50.2, 79.4), 1.7, 2.), rgb(0xF2708F));

    // The cone tips over on the scoop, which melts down onto the hair.
    let cone = rounded_polygon(&[(28.5, 4.), (57., 23.), (43., 31.5)], |_| 0.08);
    pen.fill(&cone, rgb(0xF5A0C3));
    if pen.detail == Detail::Full {
        pen.clipped(&cone, |pen| {
            let waffle = path(|p| {
                let mut offset = -10.;
                while offset <= 40. {
                    p.move_to((20. + offset, 0.)).line((offset, 40.));
                    p.move_to((10. + offset, 0.)).line((40. + offset, 40.));
                    offset += 6.5;
                }
            });
            pen.stroke(&waffle, rgb(0x9A5A3A).alpha(0.7), 0.9, 0.35);
        });
    }
    pen.stroke(&cone, rgb(0x6E4129), 1.3, 0.5);
    let scoop = path(|p| {
        p.move_to((37., 34.))
            .curve(37., 27.5, 44., 24.5, 50., 25.5)
            .curve(56., 22., 66., 24., 69., 30.)
            .curve(72., 33., 70.5, 36.5, 67., 35.5)
            .curve(66.5, 40.5, 61.5, 41., 61., 36.5)
            .curve(57., 37.5, 50., 37.5, 47.5, 36.5)
            .curve(47., 41.5, 42., 42., 42., 37.5)
            .curve(39.5, 37.5, 37., 36.5, 37., 34.);
    });
    pen.fill(&scoop, rgb(0xF7E8C9));
    pen.stroke(&scoop, rgb(0x8C5A2B), 1.3, 0.5);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_names_round_trip_and_legacy_shapes_map_to_characters() {
        for character in Character::ALL {
            assert_eq!(Character::from_raw(character.raw()), Some(character));
            assert!(character.default_personality().is_some());
        }
        for tint in Tint::ALL {
            assert_eq!(Tint::from_raw(tint.raw()), Some(tint));
        }
        assert_eq!(Character::from_raw("blob"), Some(Character::Alien));
        assert_eq!(Character::from_raw("sprout"), Some(Character::Cherry));
        assert_eq!(Character::from_raw("future"), None);
        assert_eq!(Character::Brulee.default_tint(), Tint::Rose);
        assert_eq!(Character::Teddy.default_name(), "Teddy");
    }

    #[test]
    fn every_avatar_is_a_bounded_well_formed_svg_at_every_detail() {
        for character in Character::ALL {
            for tint in Tint::ALL {
                for side in [16., 26., 56.] {
                    let svg = svg(character, tint, side, (side * 3.) as u32, 1.);
                    assert!(svg.starts_with("<svg xmlns=\"http://www.w3.org/2000/svg\""));
                    assert!(svg.ends_with("</svg>"));
                    assert!(svg.contains(&format!("width=\"{}\"", (side * 3.) as u32)));
                    assert!(!svg.contains("NaN") && !svg.contains("inf"));
                    assert_eq!(svg.matches("<g").count(), svg.matches("</g>").count());
                    assert_eq!(
                        svg.matches("<clipPath").count(),
                        svg.matches("</clipPath>").count()
                    );
                    assert!(svg.len() < 64 * 1024, "{character:?} {}", svg.len());
                }
            }
        }
    }

    #[test]
    fn body_takes_the_tint_and_small_sizes_drop_fine_details() {
        let leaf = svg(Character::Alien, Tint::Leaf, 56., 168, 1.);
        let sky = svg(Character::Alien, Tint::Sky, 56., 168, 1.);
        assert!(leaf.contains("fill=\"#74c163\""));
        assert!(sky.contains("fill=\"#63aef2\"") && !sky.contains("#74c163"));
        // Sparkles (grey fill) appear only at full detail.
        assert!(leaf.contains("#a9a8a4"));
        assert!(!svg(Character::Alien, Tint::Leaf, 26., 78, 1.).contains("#a9a8a4"));
        // Lines never get thinner than their on-screen minimum.
        let tiny = svg(Character::Croissant, Tint::Tangerine, 16., 48, 1.);
        assert!(tiny.contains("stroke-width=\"5.625\""));
        // Deterministic output, so rendered images can be cached by content.
        assert_eq!(leaf, svg(Character::Alien, Tint::Leaf, 56., 168, 1.));
    }

    #[test]
    fn readable_features_fall_back_to_ink_on_matching_bodies() {
        let green = rgb(0x2A6B2E);
        assert_eq!(readable(green, Color::hex(Tint::Sunflower.rgb())), green);
        assert_eq!(readable(green, green), rgb(INK));
        assert_eq!(number(-0.0001), "0");
        assert_eq!(number(2.5), "2.5");
        assert_eq!(number(3.), "3");
    }
}
