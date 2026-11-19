#include "Test.hpp"

#include "UI/Gui.hpp"

using namespace lm;

namespace {

// A panel at the origin, 300 x 400. With the default style its first row is at y = 34
// and every next one 25 lower; a field starts at x = 115 and a row ends at x = 292.
struct Fixture {
    Canvas canvas;
    Input input;
    Gui gui;

    void frame(const std::function<void(Gui&)>& body) {
        canvas.begin(Vec2{800, 600});
        gui.begin(canvas, input);
        gui.beginPanel("Test", Vec2{0, 0}, Vec2{300, 400});
        body(gui);
        gui.endPanel();
        gui.end();
        input.endFrame();
    }
    void moveTo(float x, float y) {
        Vec2 target{x, y};
        input.handleMouseMove(target, target - input.mousePosition());
    }
    void press() { input.handleMouseButton(MouseButton::Left, true); }
    void release() { input.handleMouseButton(MouseButton::Left, false); }
    void type(const char* text) {
        for (const char* c = text; *c; c++) input.handleText(uint32_t(*c));
    }
    void tap(Key key) {
        input.handleKey(key, true);
        input.handleKey(key, false);
    }
    static float rowY(int row) { return 34.0f + 25.0f * float(row) + 11.0f; }
};

}  // namespace

TEST(gui_button_reports_one_click_and_claims_the_mouse) {
    Fixture f;
    int clicks = 0;
    auto body = [&](Gui& gui) {
        if (gui.button("Go")) clicks++;
    };
    f.frame(body);
    CHECK(!f.gui.wantsMouse());                 // no panel has been seen yet
    f.moveTo(150, Fixture::rowY(0));
    f.frame(body);
    CHECK(f.gui.wantsMouse());
    CHECK(clicks == 0);
    f.press();
    f.frame(body);
    CHECK(clicks == 1);
    f.frame(body);                              // still held: no second click
    CHECK(clicks == 1);
    f.release();
    f.frame(body);
    f.moveTo(600, 300);                         // away from every panel
    f.frame(body);
    f.frame(body);
    CHECK(!f.gui.wantsMouse());
    f.press();
    f.frame(body);
    CHECK(clicks == 1);
}

TEST(gui_checkbox_and_button_row) {
    Fixture f;
    bool value = false;
    int chosen = -1;
    auto body = [&](Gui& gui) {
        gui.checkbox("Shadows", value);
        int clicked = gui.buttonRow({"A", "B", "C"});
        if (clicked >= 0) chosen = clicked;
    };
    f.moveTo(120, Fixture::rowY(0));
    f.press();
    f.frame(body);
    CHECK(value);
    CHECK(f.gui.changed());
    f.release();
    f.frame(body);
    CHECK(!f.gui.changed());
    f.moveTo(280, Fixture::rowY(1));            // the third of three buttons
    f.press();
    f.frame(body);
    CHECK(chosen == 2);
}

TEST(gui_drag_changes_a_number_and_respects_its_limits) {
    Fixture f;
    float value = 1.0f;
    auto body = [&](Gui& gui) { gui.dragFloat("Radius", value, 0.1f, 0.0f, 4.0f); };
    f.moveTo(150, Fixture::rowY(0));
    f.press();
    f.frame(body);
    CHECK_NEAR(value, 1.0, 1e-6);
    f.moveTo(170, Fixture::rowY(0));            // 20 points to the right
    f.frame(body);
    CHECK_NEAR(value, 3.0, 1e-5);
    CHECK(f.gui.changed());
    CHECK(f.gui.isBusy());
    f.moveTo(400, 500);                         // far outside the field: the drag goes on
    f.frame(body);
    CHECK_NEAR(value, 4.0, 1e-6);               // clamped
    f.release();
    f.frame(body);
    CHECK(!f.gui.isBusy());
}

TEST(gui_click_on_a_number_lets_you_type_it) {
    Fixture f;
    float value = 1.5f;
    auto body = [&](Gui& gui) { gui.dragFloat("Mass", value); };
    f.moveTo(150, Fixture::rowY(0));
    f.press();
    f.frame(body);
    f.release();
    f.frame(body);                              // released without moving: now editing
    CHECK(f.gui.wantsKeyboard());
    f.type("42");                               // replaces the old text, which starts selected
    f.frame(body);
    f.type(".5");
    f.frame(body);
    CHECK_NEAR(value, 1.5, 1e-6);               // nothing changes until it is confirmed
    f.tap(Key::Enter);
    f.frame(body);
    CHECK_NEAR(value, 42.5, 1e-5);
    CHECK(!f.gui.wantsKeyboard());

    // Something that is not a number leaves the value alone.
    f.press();
    f.frame(body);
    f.release();
    f.frame(body);
    f.type("abc");
    f.frame(body);
    f.tap(Key::Enter);
    f.frame(body);
    CHECK_NEAR(value, 42.5, 1e-5);
}

TEST(gui_text_field_confirms_with_enter_and_cancels_with_escape) {
    Fixture f;
    std::string name = "Crate";
    int confirmed = 0;
    auto body = [&](Gui& gui) {
        if (gui.textField("Name", name)) confirmed++;
    };
    f.moveTo(150, Fixture::rowY(0));
    f.press();
    f.frame(body);
    f.release();
    f.frame(body);
    CHECK(f.gui.wantsKeyboard());
    f.tap(Key::Backspace);                      // the text starts selected: this clears it
    f.frame(body);
    f.type("Box \xC3\xA8");                     // handleText takes code points; these two bytes are typed as two
    f.frame(body);
    f.tap(Key::Backspace);
    f.frame(body);
    f.tap(Key::Backspace);
    f.frame(body);
    f.tap(Key::Enter);
    f.frame(body);
    CHECK(name == "Box ");
    CHECK(confirmed == 1);

    f.press();
    f.frame(body);
    f.release();
    f.frame(body);
    f.type("zzz");
    f.frame(body);
    f.tap(Key::Escape);
    f.frame(body);
    f.frame(body);
    CHECK(name == "Box ");
    CHECK(confirmed == 1);
    CHECK(!f.gui.wantsKeyboard());
}

TEST(gui_combo_opens_a_list_and_takes_the_choice) {
    Fixture f;
    int index = 0;
    int hidden = 0;
    std::vector<std::string> items = {"cube", "sphere", "plane"};
    auto body = [&](Gui& gui) {
        gui.combo("Mesh", index, items);
        if (gui.button("Under the list")) hidden++;
    };
    f.moveTo(150, Fixture::rowY(0));
    f.press();
    f.frame(body);                              // opens
    f.release();
    f.frame(body);
    CHECK(f.gui.wantsMouse());
    // The list hangs below the field: its second item covers the button on the next row.
    f.moveTo(150, 34 + 22 + 22 + 11);
    f.press();
    f.frame(body);
    CHECK(hidden == 0);                         // the button under the list did not react
    f.release();
    f.frame(body);                              // the choice arrives one frame later
    CHECK(index == 1);
    CHECK(f.gui.changed());
    f.frame(body);
    f.moveTo(600, 300);
    f.frame(body);
    f.frame(body);
    CHECK(!f.gui.wantsMouse());                 // closed again
}

TEST(gui_rows_scrolled_out_of_a_panel_do_not_react) {
    Fixture f;
    int clicks = 0;
    auto body = [&](Gui& gui) {
        for (int i = 0; i < 40; i++) {
            if (gui.button("Row " + std::to_string(i))) clicks += 1000 + i;
        }
    };
    // 40 rows do not fit in 400 points. The rows past the bottom edge are not there.
    f.moveTo(150, 395);
    f.press();
    f.frame(body);
    CHECK(clicks == 0);
    f.release();
    f.frame(body);
    f.input.handleScroll(-2);                   // scroll down by four rows
    f.frame(body);
    f.moveTo(150, Fixture::rowY(0));
    f.press();
    f.frame(body);
    CHECK(clicks == 1004);
}
