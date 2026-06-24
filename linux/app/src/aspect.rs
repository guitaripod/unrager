//! A height-for-width layout manager: sizes its single child's height to
//! `width / ratio`, so an image container grows to show the whole picture as
//! the column widens.
//!
//! `gtk::Picture` reports a constant-size request here (its height doesn't
//! track the allocated width), and `AdwClamp` / `GtkAspectFrame` collapse the
//! child to its natural/min height — all of which left inline media cropped to
//! a short band. This re-measures automatically on resize, with no per-frame
//! tick callback.

use gtk::glib;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use std::cell::Cell;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct AspectLayout {
        pub ratio: Cell<f32>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for AspectLayout {
        const NAME: &'static str = "UnragerAspectLayout";
        type Type = super::AspectLayout;
        type ParentType = gtk::LayoutManager;
    }

    impl ObjectImpl for AspectLayout {}

    impl LayoutManagerImpl for AspectLayout {
        fn request_mode(&self, _widget: &gtk::Widget) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        fn measure(
            &self,
            _widget: &gtk::Widget,
            orientation: gtk::Orientation,
            for_size: i32,
        ) -> (i32, i32, i32, i32) {
            if orientation == gtk::Orientation::Horizontal {
                // No intrinsic width — fill whatever the column (or clamp) gives.
                (0, 0, -1, -1)
            } else {
                let ratio = self.ratio.get().max(0.01);
                let width = for_size.max(0);
                let height = ((width as f32 / ratio).round() as i32).max(1);
                (height, height, -1, -1)
            }
        }

        fn allocate(&self, widget: &gtk::Widget, width: i32, height: i32, baseline: i32) {
            if let Some(child) = widget.first_child() {
                child.allocate(width, height, baseline, None);
            }
        }
    }
}

glib::wrapper! {
    pub struct AspectLayout(ObjectSubclass<imp::AspectLayout>) @extends gtk::LayoutManager;
}

impl AspectLayout {
    pub fn new(ratio: f32) -> Self {
        let layout: Self = glib::Object::new();
        layout.imp().ratio.set(ratio);
        layout
    }
}

/// Wraps `child` in a widget whose height tracks its width at `ratio`
/// (width ÷ height), so the child fills the column and grows tall enough to
/// show the whole image.
pub fn aspect_box(child: &impl IsA<gtk::Widget>, ratio: f32) -> gtk::Widget {
    let container = gtk::Box::new(gtk::Orientation::Vertical, 0);
    container.set_layout_manager(Some(AspectLayout::new(ratio)));
    container.set_hexpand(true);
    container.append(child);
    container.upcast()
}
