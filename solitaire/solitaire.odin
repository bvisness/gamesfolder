package minesweeper

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"

V2 :: [2]f32

// This is just what SDL does I guess
MOUSE_LEFT :: 1
MOUSE_RIGHT :: 3
CLICK_RELEASE_RADIUS :: 20
DRAG_THRESHOLD :: 4

// When I figured out how to lay everything out the way I liked, I used a card size of 300x400.
// But this is too big for actual gameplay, hence CARD_SIZE is smaller. Rather than hardcode a
// bunch of new magic numbers here, we stick with what we have and just scale them all by a
// CARD_SCALE derived from CARD_SIZE and CARD_NOMINAL SIZE.
CARD_SIZE :: V2{150, 200}
CARD_NOMINAL_SIZE :: V2{300, 400}
CARD_SCALE :: CARD_SIZE.x / CARD_NOMINAL_SIZE.x

GAME_PADDING :: 40
PILE_GAP :: 20
WINDOW_SIZE :: V2{GAME_PADDING * 2 + CARD_SIZE.x * 7 + PILE_GAP * 6, 1000}

DECK_POS :: V2{GAME_PADDING, GAME_PADDING}
FOUNDATION_POS :: V2{WINDOW_SIZE.x - GAME_PADDING - CARD_SIZE.x * 4 - PILE_GAP * 3, GAME_PADDING}
MAIN_Y :: GAME_PADDING + CARD_SIZE.y + 40
COLUMN_SPREAD :: 35

CARD_DROP_RADIUS :: V2{CARD_SIZE.x / 2 - 10, CARD_SIZE.y - 40}

// ----------------------------------------------------------------------------
// Game logic

Suit :: enum u8 {
	CLUBS = 1,
	SPADES,
	DIAMONDS,
	HEARTS,
}

Card :: struct {
	number:   u8, // 0 is invalid, 1 = A, 2 = 2, etc.
	suit:     Suit,

	// Rendering/animating/interpolating
	face_up:  bool,
	last_pos: V2,
}

Pile :: [dynamic; 52]Card

Animation :: enum {
	NONE,
	DEAL,
	BOUNCE,
}

GameState :: struct {
	deck:             Pile,
	draw_pile:        Pile,
	piles:            [7]Pile,
	columns:          [7]Pile,
	foundations:      [4]Pile,

	// Click and drag
	dragging_column:  Pile,
	drag_return_pile: ^Pile,

	// Animation-related shenanigans
	animation:        Animation,
	num_dealt:        int,
}
game_state: GameState

init_game :: proc() {
	game_state = GameState{}

	// Make and shuffle the deck
	for suit in 1 ..= 4 {
		for n in 1 ..= 13 {
			append(&game_state.deck, Card{number = u8(n), suit = Suit(suit), last_pos = DECK_POS})
		}
	}
	rand.shuffle(game_state.deck[:])

	// Initial deal
	for _, i in game_state.piles {
		num_cards := i + 1
		for n in 0 ..< num_cards {
			// append(pile, c) // For some reason referencing &pile in the loop and doing this doesn't work, thanks Bill
			card := pop(&game_state.deck)
			if n == num_cards - 1 {
				card.face_up = true
				append(&game_state.columns[i], card)
			} else {
				append(&game_state.piles[i], card)
			}
		}
	}
}

suit_is_red :: #force_inline proc(s: Suit) -> bool {
	return s == .DIAMONDS || s == .HEARTS
}

card_rect :: proc(pos: V2) -> sdl3.FRect {
	return sdl3.FRect {
		pos.x,
		pos.y,
		CARD_NOMINAL_SIZE.x * CARD_SCALE,
		CARD_NOMINAL_SIZE.y * CARD_SCALE,
	}
}

card_drop_rect :: proc(pos: V2) -> sdl3.FRect {
	return sdl3.FRect {
		pos.x - CARD_DROP_RADIUS.x,
		pos.y - CARD_DROP_RADIUS.y,
		CARD_DROP_RADIUS.x * 2,
		CARD_DROP_RADIUS.y * 2,
	}
}

card_id :: proc(card: Card, allocator := context.allocator) -> string {
	return fmt.aprintf("card:S%dN%d", card.suit, card.number)
}

// ----------------------------------------------------------------------------
// Textures

TextureDrawMode :: enum {
	NORMAL,
	NINESLICE,
	NINESLICE_TILED,
}

Texture :: struct {
	mode:        TextureDrawMode,
	src:         Maybe(sdl3.FRect),
	slices:      [4]f32, // left, right, top, bottom
	slice_scale: f32,

	// Filled in when loading
	tex:         ^sdl3.Texture,
	size:        V2,
	full_rect:   sdl3.FRect,
}

texture_grid :: proc "contextless" (
	$N: int,
	template: Texture,
	start: V2,
	size: V2,
	offset: V2,
	per_row: int,
) -> (
	res: [N]Texture,
) {
	for _, i in res {
		row := f32(i / per_row)
		col := f32(i % per_row)

		res[i] = template
		res[i].src = sdl3.FRect{start.x + col * offset.x, start.y + row * offset.y, size.x, size.y}
	}
	return
}

t_card := Texture {
	mode        = .NINESLICE,
	src         = sdl3.FRect{260, 260, 400, 605},
	slices      = {65, 65, 65, 65},
	slice_scale = 0.4 * CARD_SCALE,
}
t_card_back := Texture {
	src = sdl3.FRect{2255, 1300, 605, 805},
}
t_clubs := texture_grid(4, Texture{}, {850, 250}, {1230 - 1054, 642 - 449}, {200, 200}, 2)
t_spades := texture_grid(4, Texture{}, {1300, 250}, {150, 195}, {200, 250}, 2)
t_diamonds := texture_grid(4, Texture{}, {1750, 250}, {150, 200}, {150, 250}, 2)
t_hearts := texture_grid(4, Texture{}, {2150, 250}, {170, 170}, {200, 200}, 2)
t_numbers := texture_grid(26, Texture{}, {850, 750}, {145, 200}, {150, 250}, 13)
t_face := texture_grid(6, Texture{}, {850, 1300}, {415, 610}, {450, 650}, 3)

load_textures :: proc() {
	load_textures_from_png("resources/solitaire.png", &t_card, &t_card_back)
	load_texture_slice_from_png(
		"resources/solitaire.png",
		t_clubs[:],
		t_spades[:],
		t_diamonds[:],
		t_hearts[:],
		t_numbers[:],
		t_face[:],
	)
}

card_tnum :: proc(c: Card) -> ^Texture {
	assert(1 <= c.number && c.number <= 13)
	n := c.number - 1
	return &t_numbers[(suit_is_red(c.suit) ? 13 : 0) + n]
}

card_tsuit :: proc(c: Card, variant: int) -> ^Texture {
	assert(0 < u8(c.suit) && u8(c.suit) <= 4)
	assert(0 <= variant && variant < 4)
	suits := [4]^[4]Texture{&t_clubs, &t_spades, &t_diamonds, &t_hearts}
	suit := suits[u8(c.suit) - 1]
	return &suit[variant]
}

card_tface :: proc(c: Card) -> ^Texture {
	assert(11 <= c.number && c.number <= 13)
	n := c.number - 11
	return &t_face[(suit_is_red(c.suit) ? 3 : 0) + n]
}

PipInfo :: struct {
	col:         u8,
	row:         u8,
	upside_down: bool,
}

pip_nrows := []int {
	0, // invalid
	0, // A, invalid
	2, // 2
	3, // 3
	2, // 4
	3, // 5
	3, // 6
	5, // 7
	5, // 8
	7, // 9
	7, // 10
	0, // J, invalid
	0, // Q, invalid
	0, // K, invalid
}
pip_specs := [][]PipInfo {
	{}, // invalid
	{}, // A, invalid
	{{1, 0, false}, {1, 1, true}}, // 2
	{{1, 0, false}, {1, 1, false}, {1, 2, true}}, // 3
	{{0, 0, false}, {2, 0, false}, {0, 1, true}, {2, 1, true}}, // 4
	{{0, 0, false}, {2, 0, false}, {0, 2, true}, {2, 2, true}, {1, 1, false}}, // 5
	{{0, 0, false}, {0, 1, false}, {0, 2, true}, {2, 0, false}, {2, 1, false}, {2, 2, true}}, // 6
	{
		{0, 0, false},
		{0, 2, false},
		{0, 4, true},
		{2, 0, false},
		{2, 2, false},
		{2, 4, true},
		{1, 1, false},
	}, // 7
	{
		{0, 0, false},
		{0, 2, false},
		{0, 4, true},
		{2, 0, false},
		{2, 2, false},
		{2, 4, true},
		{1, 1, false},
		{1, 3, true},
	}, // 8
	{
		{0, 0, false},
		{0, 2, false},
		{0, 4, true},
		{0, 6, true},
		{2, 0, false},
		{2, 2, false},
		{2, 4, true},
		{2, 6, true},
		{1, 3, false},
	}, // 9
	{
		{0, 0, false},
		{0, 2, false},
		{0, 4, true},
		{0, 6, true},
		{2, 0, false},
		{2, 2, false},
		{2, 4, true},
		{2, 6, true},
		{1, 1, false},
		{1, 5, true},
	}, // 10
	{}, // J, invalid
	{}, // Q, invalid
	{}, // K, invalid
}

// ----------------------------------------------------------------------------
// Utilities

trapf :: proc(msg: string, args: ..any, location := #caller_location) {
	log.errorf(msg, ..args, location = location)
	intrinsics.debug_trap()
}

must :: proc(val: $T, msg: string, args: ..any, location := #caller_location) -> T {
	zero: T
	if val == zero {
		log.errorf(msg, ..args, location = location)
		intrinsics.debug_trap()
	}
	return val
}

must1 :: proc(val: $T, err: $E, msg: string, args: ..any, location := #caller_location) -> T {
	zero: E
	if err != zero {
		log.errorf(msg, ..args, location = location)
		log.errorf("Crashed with error: %v.", err, location = location)
		intrinsics.debug_trap()
	}
	return val
}

rect_xy :: proc(r: sdl3.FRect) -> V2 {
	return {r.x, r.y}
}

rect_wh :: #force_inline proc(r: sdl3.FRect) -> V2 {
	return {r.x, r.y}
}

// ----------------------------------------------------------------------------
// Loading & initialization

CTX :: struct {
	window:               ^sdl3.Window,
	canvas:               ^sdl3.Texture,
	renderer:             ^sdl3.Renderer,
	should_close:         bool,

	// Size
	window_size:          [2]i32,

	// Timing
	t:                    f64,
	dt:                   f64,
	dirty:                bool,

	// Input
	mouse_pos:            sdl3.FPoint,
	mouse_down:           [10]bool,
	mouse_pressed:        [10]bool,
	mouse_released:       [10]bool,

	// UI state
	hot_item_buf:         [256]byte,
	hot_item:             string,
	hot_mouse_button:     int,
	drag_supported:       bool,
	dragging:             bool,
	drag_canceled:        bool,
	drag_start_item_pos:  V2,
	drag_start_mouse_pos: V2,
	potential_hot_items:  [dynamic]PotentialHotItem,

	// UI actions for hot item

	// This only means that the mouse went up, NOT that the mouse went up in the
	// right place. If your UI control cares about this, e.g. to avoid activating
	// a button on release when it moved too far away, filter for this in the UI
	// control.
	clicked:              bool,

	// The hot item had a drag started on it this frame.
	drag_started:         bool,

	// The hot item was dropped this frame.
	drag_ended:           bool,
}
ctx := CTX{}

PotentialHotItem :: struct {
	rect:             sdl3.FRect,
	id:               string,
	support_dragging: bool,
}

init_sdl :: proc() {
	must(
		sdl3.SetAppMetadata("Solitaire", "0.1", "me.bvisness.gamesfolder.solitaire"),
		"sdl3.SetAppMetadata failed.",
	)
	must(sdl3.Init(sdl3.INIT_VIDEO), "sdl3.Init failed.")

	must(
		sdl3.CreateWindowAndRenderer(
			"Solitaire",
			i32(WINDOW_SIZE.x),
			i32(WINDOW_SIZE.y),
			sdl3.WindowFlags{},
			&ctx.window,
			&ctx.renderer,
		),
		"sdl3.CreateWindowAndRenderer failed.",
	)

	ctx.canvas = must(
		sdl3.CreateTexture(
			ctx.renderer,
			.RGBA8888,
			.TARGET,
			i32(WINDOW_SIZE.x),
			i32(WINDOW_SIZE.y),
		),
		"Failed to create canvas texture",
	)
}

cleanup :: proc() {
	sdl3.DestroyWindow(ctx.window)
	sdl3.Quit()
}

load_textures_from_png :: proc(path: string, textures: ..^Texture) {
	fullpath := must1(
		filepath.join([]string{string(sdl3.GetBasePath()), path}, context.temp_allocator),
		"Failed to join path.",
	)
	res := must(
		strings.clone_to_cstring(fullpath, context.temp_allocator),
		"Failed to load image %s.",
		path,
	)

	surface := must(sdl3.LoadPNG(res), "Failed to load bitmap %s: %s.", path, sdl3.GetError())
	defer sdl3.DestroySurface(surface)

	sdl_tex := must(
		sdl3.CreateTextureFromSurface(ctx.renderer, surface),
		"Failed to create texture for %s: %s.",
		path,
		sdl3.GetError(),
	)

	for tex in textures {
		tex.tex = sdl_tex
		if src, ok := tex.src.?; ok {
			tex.size = {src.w, src.h}
		} else {
			tex.size = {f32(surface.w), f32(surface.h)}
		}
		tex.full_rect = sdl3.FRect{0, 0, f32(surface.w), f32(surface.h)}
	}
}

load_texture_slice_from_png :: proc(path: string, textures: ..[]Texture) {
	total_len := 0
	for texes in textures {
		total_len += len(texes)
	}
	ptrs := make([]^Texture, total_len, context.temp_allocator)
	i := 0
	for texes in textures {
		for _, j in texes {
			ptrs[i] = &texes[j]
			i += 1
		}
	}
	load_textures_from_png(path, ..ptrs)
}

// ----------------------------------------------------------------------------
// UI state

advertise_hotness :: proc(id: string, rect: sdl3.FRect, support_dragging: bool) {
	target := PotentialHotItem {
		rect             = rect,
		id               = id,
		support_dragging = support_dragging,
	}
	append(&ctx.potential_hot_items, target)
}

// Sets an item as hot, enabling interactions on future frames. Marks the
// context dirty.
set_hot :: proc(target: PotentialHotItem, hot_mouse_button: int) {
	assert(ctx.hot_item == "")

	copy_from_string(ctx.hot_item_buf[:], target.id)
	ctx.hot_item = string(ctx.hot_item_buf[:len(target.id)])
	ctx.hot_mouse_button = hot_mouse_button
	ctx.dragging = false
	ctx.drag_supported = target.support_dragging
	ctx.drag_started = false
	ctx.drag_canceled = false
	ctx.drag_start_item_pos = rect_xy(target.rect)
	ctx.drag_start_mouse_pos = V2(ctx.mouse_pos)
	log.infof(
		"UI: NOW HOT: %s, btn %d (%s)",
		ctx.hot_item,
		ctx.hot_mouse_button,
		ctx.drag_supported ? "draggable" : "not draggable",
	)

	ctx.dirty = true
}

check_hover :: proc(id: string, rect: sdl3.FRect) -> bool {
	return ctx.hot_item == "" && sdl3.PointInRectFloat(ctx.mouse_pos, rect)
}

check_active :: proc(id: string, rect: sdl3.FRect) -> bool {
	if ctx.hot_item == id {
		if ctx.dragging {
			return false
		}

		// We still check the radius here because maybe not everything supports dragging.
		release_rect := sdl3.FRect {
			rect.x - CLICK_RELEASE_RADIUS,
			rect.y - CLICK_RELEASE_RADIUS,
			rect.w + 2 * CLICK_RELEASE_RADIUS,
			rect.h + 2 * CLICK_RELEASE_RADIUS,
		}
		return sdl3.PointInRectFloat(ctx.mouse_pos, release_rect)
	}

	return false
}

check_clicked :: proc(id: string, rect: sdl3.FRect) -> int {
	if ctx.hot_item == id && ctx.clicked {
		// We still check the radius here because maybe not everything supports dragging.
		release_rect := sdl3.FRect {
			rect.x - CLICK_RELEASE_RADIUS,
			rect.y - CLICK_RELEASE_RADIUS,
			rect.w + 2 * CLICK_RELEASE_RADIUS,
			rect.h + 2 * CLICK_RELEASE_RADIUS,
		}
		if sdl3.PointInRectFloat(ctx.mouse_pos, release_rect) {
			log.infof("id %s clicked!", ctx.hot_item)
			ctx.dirty = true
			return ctx.hot_mouse_button
		}
	}

	return 0
}

// Checks if a drag was started.
check_drag_started :: proc(id: string) -> bool {
	return ctx.hot_item == id && ctx.drag_started
}

// This one doesn't take an ID because the UI elements who call this will just
// check on their own to see if they can receive whatever is being dragged.
check_drag_ended :: proc() -> (bool, V2) {
	if ctx.drag_ended {
		return true, drag_item_pos()
	} else {
		return false, {}
	}
}

// Clears the current UI action. Also marks the context as dirty to make sure
// things always re-draw afterward.
clear_ui_action :: proc() {
	ctx.clicked = false
	ctx.drag_started = false
	ctx.drag_ended = false
	ctx.dirty = true
}

drag_delta :: proc() -> V2 {
	// assert(ctx.dragging)
	return V2(ctx.mouse_pos) - ctx.drag_start_mouse_pos
}

drag_item_pos :: proc() -> V2 {
	// assert(ctx.dragging)
	return ctx.drag_start_item_pos + drag_delta()
}

// ----------------------------------------------------------------------------
// Rendering

card_variant := 0

next_variant :: proc() -> int {
	res := card_variant
	card_variant = (card_variant + 1) % 4
	return res
}

draw :: proc() {
	sdl3.SetRenderTarget(ctx.renderer, ctx.canvas)
	sdl3.SetRenderDrawColor(ctx.renderer, 19, 127, 49, 255)
	sdl3.RenderClear(ctx.renderer)

	// Draw the deck
	{
		id := "deck"
		rect := sdl3.FRect{DECK_POS.x, DECK_POS.y, CARD_SIZE.x, CARD_SIZE.y}
		draw_pile(&game_state.deck, DECK_POS, true)
		advertise_hotness(id, rect, false)

		if mouse_btn := check_clicked(id, rect); mouse_btn == MOUSE_LEFT {
			clear_ui_action()
			if len(game_state.deck) > 0 {
				for _ in 0 ..< min(len(game_state.deck), 3) {
					card := pop(&game_state.deck)
					card.face_up = true
					append(&game_state.draw_pile, card)
				}
			} else {
				n := len(game_state.draw_pile)
				for _ in 0 ..< n {
					card := pop(&game_state.draw_pile)
					card.face_up = false
					append(&game_state.deck, card)
				}
			}
		}
	}

	// Draw the draw pile
	{
		pile_pos := DECK_POS + {CARD_SIZE.x + PILE_GAP, 0}
		pile_top_rect := draw_pile(&game_state.draw_pile, pile_pos, true)

		if len(game_state.draw_pile) > 0 {
			top_card := game_state.draw_pile[len(game_state.draw_pile) - 1]
			id := card_id(top_card)
			advertise_hotness(id, pile_top_rect, true)
			if check_drag_started(id) {
				clear_ui_action()
				pop(&game_state.draw_pile)
				append(&game_state.dragging_column, top_card)
				game_state.drag_return_pile = &game_state.draw_pile
			}
		}
	}

	// Draw the piles and columns
	for i in 0 ..< 7 {
		pile := &game_state.piles[i]
		column := &game_state.columns[i]

		pile_id := fmt.tprintf("pile:%d", i)
		pile_pos := V2{GAME_PADDING + f32(i) * (CARD_SIZE.x + PILE_GAP), MAIN_Y}
		pile_top_rect := draw_pile(pile, pile_pos, false)
		if len(pile) > 0 {
			advertise_hotness(pile_id, pile_top_rect, false)
			if btn := check_clicked(pile_id, pile_top_rect); btn == MOUSE_LEFT {
				clear_ui_action()
				if len(column) == 0 {
					card := pop(pile)
					card.face_up = true
					append(column, card)
				}
			}
		}

		column_top_pos := draw_column(column, rect_xy(pile_top_rect))
		if dropped, drop_pos := check_drag_ended(); dropped {
			dropped_here := sdl3.PointInRectFloat(
				sdl3.FPoint(drop_pos),
				card_drop_rect(column_top_pos),
			)

			compatible: bool
			dragged_card := game_state.dragging_column[0]
			if len(column) > 0 {
				column_top_card := column[len(column) - 1]
				compatible =
					dragged_card.number == column_top_card.number - 1 &&
					suit_is_red(column_top_card.suit) != suit_is_red(dragged_card.suit)
			} else {
				compatible = dragged_card.number == 13 // King
			}

			if dropped_here && compatible {
				clear_ui_action()
				for card in game_state.dragging_column {
					append(column, card)
				}
				clear(&game_state.dragging_column)
				log.infof("Column now has %d cards", len(pile))
			}
		}
	}

	// Draw the foundations
	for i in 0 ..< 4 {
		id := fmt.tprintf("foundation:%d", i)
		foundation := &game_state.foundations[i]
		pos := FOUNDATION_POS + {(CARD_SIZE.x + PILE_GAP) * f32(i), 0}
		foundation_top_rect := draw_pile(foundation, pos, true)

		advertise_hotness(id, foundation_top_rect, true)
		if check_drag_started(id) {
			clear_ui_action()
			append(&game_state.dragging_column, pop(foundation))
			game_state.drag_return_pile = foundation
		}

		if len(game_state.dragging_column) == 1 {
			dragged_card := game_state.dragging_column[0]

			if dropped, drop_pos := check_drag_ended(); dropped {
				dropped_here := sdl3.PointInRectFloat(
					sdl3.FPoint(drop_pos),
					card_drop_rect(rect_xy(foundation_top_rect)),
				)

				compatible: bool
				if len(foundation) == 0 {
					compatible = dragged_card.number == 1 // Ace
				} else {
					top_card := foundation[len(foundation) - 1]
					compatible =
						dragged_card.number == top_card.number + 1 &&
						dragged_card.suit == top_card.suit
				}

				if dropped_here && compatible {
					clear_ui_action()
					append(foundation, dragged_card)
					clear(&game_state.dragging_column)
				}
			}
		}
	}

	// Draw whatever is being dragged
	if ctx.dragging {
		log.infof(
			"number of dragged cards: %v (at %v)",
			len(game_state.dragging_column),
			drag_item_pos(),
		)
	}
	if len(game_state.dragging_column) > 0 {
		draw_column(&game_state.dragging_column, drag_item_pos())
	}

	sdl3.SetRenderTarget(ctx.renderer, nil)
	sdl3.RenderTexture(ctx.renderer, ctx.canvas, nil, nil)
	sdl3.RenderPresent(ctx.renderer)
}

draw_card :: proc(card: Card, card_pos: V2) -> sdl3.FRect {
	rect := card_rect(card_pos)
	card_center := V2{rect.x + rect.w / 2, rect.y + rect.h / 2}

	if card.face_up {
		card_variant = 0
		render_texture(&t_card, rect)
		render_texture_pos_centered(
			card_tnum(card),
			card_pos + {30, 45} * CARD_SCALE,
			0.2 * CARD_SCALE,
		)
		render_texture_pos_centered(
			card_tsuit(card, next_variant()),
			card_pos + {30, 85} * CARD_SCALE,
			0.15 * CARD_SCALE,
		)
		render_texture_pos_centered(
			card_tnum(card),
			card_pos + CARD_SIZE - {30, 45} * CARD_SCALE,
			0.2 * CARD_SCALE,
			true,
		)
		render_texture_pos_centered(
			card_tsuit(card, next_variant()),
			card_pos + CARD_SIZE - {30, 85} * CARD_SCALE,
			0.15 * CARD_SCALE,
			true,
		)
		if card.number == 1 {
			render_texture_pos_centered(
				card_tsuit(card, next_variant()),
				card_center,
				0.4 * CARD_SCALE,
			)
		} else if 2 <= card.number && card.number <= 10 {
			nrows := pip_nrows[card.number]
			pip_spec := pip_specs[card.number]

			PIP_INSET_X, PIP_INSET_Y :: 84 * CARD_SCALE, 80 * CARD_SCALE
			pip_rect := sdl3.FRect {
				rect.x + PIP_INSET_X,
				rect.y + PIP_INSET_Y,
				rect.w - PIP_INSET_X * 2,
				rect.h - PIP_INSET_Y * 2,
			}
			col_width := pip_rect.w / (3 - 1)
			row_height := pip_rect.h / (f32(nrows) - 1)

			for pip in pip_spec {
				pip_pos := V2 {
					pip_rect.x + f32(pip.col) * col_width,
					pip_rect.y + f32(pip.row) * row_height,
				}
				render_texture_pos_centered(
					card_tsuit(card, next_variant()),
					pip_pos,
					0.4 * CARD_SCALE,
					pip.upside_down,
				)
			}
		} else if 11 <= card.number && card.number <= 13 {
			render_texture_pos_centered(card_tface(card), card_center, 0.5 * CARD_SCALE)
		} else {
			trapf("invalid card number %v", card.number)
		}
	} else {
		render_texture(&t_card_back, rect)
	}

	return card_rect(card_pos)
}

bumpage :: proc(n: int, up: bool) -> f32 {
	CARDS_PER_FACEDOWN :: 2
	BUMP_AMT :: 2
	return f32(n / CARDS_PER_FACEDOWN) * BUMP_AMT * (up ? -1 : 1)
}

draw_pile :: proc(pile: ^Pile, pos: V2, up: bool) -> sdl3.FRect {
	if len(pile) == 0 {
		return card_rect(pos)
	}

	top := pile[len(pile) - 1]
	num_remaining := len(pile) - 1

	for i in 0 ..< num_remaining {
		draw_card(Card{face_up = false}, {pos.x, pos.y + bumpage(i, up)})
	}
	return draw_card(top, {pos.x, pos.y + bumpage(len(pile) - 1, up)})
}

draw_column :: proc(pile: ^Pile, pos: V2) -> V2 {
	card_pos := pos
	for card, i in pile {
		id := card_id(card, context.temp_allocator)
		advertise_hotness(id, card_rect(card_pos), true)
		if check_drag_started(id) {
			clear_ui_action()
			for dragged_card in pile[i:] {
				append(&game_state.dragging_column, dragged_card)
			}
			resize(pile, i)
			game_state.drag_return_pile = pile
			break
		}

		draw_card(card, card_pos)
		card_pos = card_pos + {0, COLUMN_SPREAD}
	}
	return card_pos
}

render_texture :: proc(texture: ^Texture, dst: sdl3.FRect, upside_down := false) {
	assert(texture.tex != nil, "texture was not loaded!")
	src: Maybe(^sdl3.FRect)
	dst := dst
	if _, ok := texture.src.?; ok {
		src = &texture.src.?
	}
	scale := texture.slice_scale
	if scale == 0 {
		scale = 1
	}

	switch texture.mode {
	case .NORMAL:
		if upside_down {
			sdl3.RenderTextureRotated(ctx.renderer, texture.tex, src, &dst, 180, nil, .NONE)
		} else {
			sdl3.RenderTexture(ctx.renderer, texture.tex, src, &dst)
		}
	case .NINESLICE:
		sdl3.RenderTexture9Grid(
			ctx.renderer,
			texture.tex,
			src,
			texture.slices[0],
			texture.slices[1],
			texture.slices[2],
			texture.slices[3],
			scale,
			&dst,
		)
	case .NINESLICE_TILED:
		sdl3.RenderTexture9GridTiled(
			ctx.renderer,
			texture.tex,
			src,
			texture.slices[0],
			texture.slices[1],
			texture.slices[2],
			texture.slices[3],
			scale,
			&dst,
			scale,
		)
	case:
		trapf("bad render mode: %v", texture.mode)
	}
}

render_texture_pos :: proc(texture: ^Texture, pos: V2, scale: f32) {
	w, h := texture.size.x * scale, texture.size.y * scale
	render_texture(texture, sdl3.FRect{pos.x, pos.y, w, h})
}

render_texture_pos_centered :: proc(texture: ^Texture, pos: V2, scale: f32, upside_down := false) {
	w, h := texture.size.x * scale, texture.size.y * scale
	render_texture(texture, sdl3.FRect{pos.x - w / 2, pos.y - h / 2, w, h}, upside_down)
}

// ----------------------------------------------------------------------------
// Game loop

loop :: proc() {
	loop_context := context
	ctx.t = f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = 0.001 // default to 1ms for the first frame

	// Some jank you have to do in order to continue drawing while resizing the
	// window. https://wiki.libsdl.org/SDL3/AppFreezeDuringDrag
	ok := sdl3.AddEventWatch(proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
			context = (^runtime.Context)(userdata)^
			if event.type == .WINDOW_EXPOSED {
				sdl3.GetWindowSize(ctx.window, &ctx.window_size.x, &ctx.window_size.y)
				frame()
			}
			return true
		}, &loop_context)
	if !ok {
		log.error("sdl3.AddEventWatch failed.")
		return
	}

	for !ctx.should_close {
		free_all(context.temp_allocator)
		ctx.potential_hot_items = make([dynamic]PotentialHotItem, context.temp_allocator)

		// Reset ephemeral input state to the default
		for &pressed in ctx.mouse_pressed {
			pressed = false
		}
		for &released in ctx.mouse_released {
			released = false
		}

		// Process events
		e: sdl3.Event
		if ctx.dirty {
			// Just do a frame right away (but only one)
			ctx.dirty = false
		} else {
			// Wait for events, then process them all
			if !sdl3.WaitEvent(&e) {
				panic("failed sdl3.WaitEvent")
			}
			process_event(&e)
		}
		for sdl3.PollEvent(&e) {
			process_event(&e)
		}

		// Draw the frame / animate and whatever
		frame()

		// After drawing the UI: update UI interaction state for the next frame,
		// e.g. activating a click, starting a drag, or ending a drag. Or, mark a
		// new item as hot for future interactions.
		ctx.clicked = false
		ctx.drag_started = false
		if ctx.hot_item != "" {
			// An item is already hot, potentially activate an action on it

			if ctx.mouse_down[ctx.hot_mouse_button] {
				// If the mouse is still down, we either have a click in progress or
				// possibly have a (possibly pending) drag and drop.
				// TODO
				if ctx.drag_supported {
					drag_delta := V2(ctx.mouse_pos) - ctx.drag_start_mouse_pos
					if !ctx.dragging &&
					   (abs(drag_delta.x) >= DRAG_THRESHOLD ||
							   abs(drag_delta.y) >= DRAG_THRESHOLD) {
						log.infof("UI: ACTION: started drag.")
						ctx.dragging = true
						ctx.drag_started = true
						ctx.dirty = true
					}
				}
			} else if ctx.mouse_released[ctx.hot_mouse_button] {
				// The mouse was released this frame. We either need to report a click
				// or a drop (or nothing, if the drag was canceled!) Regardless, we
				// don't yet clear out the hot item until the next frame.
				if ctx.dragging {
					if !ctx.drag_canceled {
						log.infof("UI: ACTION: ended drag.")
						ctx.drag_ended = true
						ctx.dirty = true
					}
				} else {
					log.infof("UI: ACTION: clicked.")
					ctx.clicked = true
					ctx.dirty = true
				}
			} else {
				// The mouse has been up for at least two frames; all UI interaction
				// state should be cleared.
				log.infof("UI: Resetting all interaction state.")

				ctx.hot_item = ""
				ctx.hot_mouse_button = 0
				ctx.drag_supported = false
				ctx.dragging = false
				ctx.drag_canceled = false
				ctx.drag_start_item_pos = {}
				ctx.drag_start_mouse_pos = {}

				clear_ui_action()
				ctx.dirty = true
			}
		} else {
			// No hot item; check for a new one

			// Loop over potentially hot things in reverse order because we drew them
			// in forward order...I am good porgrammer
			check_more: for i := len(ctx.potential_hot_items) - 1; i >= 0; i -= 1 {
				potential_item := ctx.potential_hot_items[i]
				if sdl3.PointInRectFloat(sdl3.FPoint(ctx.mouse_pos), potential_item.rect) {
					// BILL! Why do I need parens here, Bill????
					for btn in ([]int{MOUSE_LEFT, MOUSE_RIGHT}) {
						if ctx.mouse_pressed[btn] {
							set_hot(potential_item, btn)
							break check_more
						}
					}
				}
			}
		}

		// Final cleanup: handle any canceled drag and drops by putting the
		// cards back.
		if !ctx.dragging && len(game_state.dragging_column) > 0 {
			for card in game_state.dragging_column {
				append(game_state.drag_return_pile, card)
			}
			clear(&game_state.dragging_column)
		}
	}
}

process_event :: proc(e: ^sdl3.Event) {
	#partial switch (e.type) {
	case .QUIT:
		ctx.should_close = true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		ctx.mouse_pressed[e.button.button] = !ctx.mouse_down[e.button.button] && e.button.down
		ctx.mouse_released[e.button.button] = ctx.mouse_down[e.button.button] && !e.button.down
		ctx.mouse_down[e.button.button] = e.button.down
	case .KEY_DOWN:
		switch e.key.key {
		case sdl3.K_ESCAPE:
			if ctx.dragging {
				ctx.drag_canceled = true
			}
		}
	case .MOUSE_MOTION:
		ctx.mouse_pos = {e.motion.x, e.motion.y}
	case .WINDOW_RESIZED:
		sdl3.GetWindowSize(ctx.window, &ctx.window_size.x, &ctx.window_size.y)
		log.infof("Window now has size: %v.", ctx.window_size)
	}
}

frame :: proc() {
	draw()

	new_t := f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = new_t - ctx.t
	ctx.t = new_t
}

// ----------------------------------------------------------------------------
// Main

main :: proc() {
	context.logger = log.create_console_logger()

	init_sdl()
	defer cleanup()

	load_textures()
	init_game()

	loop()

	log.info("Done.")
}
