package minesweeper

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"

V2 :: [2]f32

// This is just what SDL does I guess
MOUSE_LEFT :: 1
MOUSE_RIGHT :: 3
CLICK_RELEASE_RADIUS :: 20

// When I figured out how to lay everything out the way I liked, I used a card size of 300x400.
// But this is too big for actual gameplay, hence CARD_SIZE is smaller. Rather than hardcode a
// bunch of new magic numbers here, we stick with what we have and just scale them all by a
// CARD_SCALE derived from CARD_SIZE and CARD_NOMINAL SIZE.
CARD_SIZE :: V2{150, 200}
CARD_NOMINAL_SIZE :: V2{300, 400}
CARD_SCALE :: CARD_SIZE.x / CARD_NOMINAL_SIZE.x

GAME_PADDING :: 40
PILE_GAP :: 20
WINDOW_SIZE :: V2{GAME_PADDING * 2 + CARD_SIZE.x * 7 + PILE_GAP * 6, 800}

DECK_POS :: V2{GAME_PADDING, GAME_PADDING}
FOUNDATION_POS :: V2{WINDOW_SIZE.x - GAME_PADDING - CARD_SIZE.x * 4 - PILE_GAP * 3, GAME_PADDING}
MAIN_Y :: GAME_PADDING + CARD_SIZE.y + 40
COLUMN_SPREAD :: 20

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
	deck:        Pile,
	draw_pile:   Pile,
	piles:       [7]Pile,
	columns:     [7]Pile,
	foundations: [4]Pile,

	// Animation-related shenanigans
	animation:   Animation,
	num_dealt:   int,
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

lay_out_cards :: proc() {}

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
	window:           ^sdl3.Window,
	renderer:         ^sdl3.Renderer,
	should_close:     bool,

	// Size
	window_size:      [2]i32,

	// Timing
	t:                f64,
	dt:               f64,
	dirty:            bool,

	// Input
	mouse_pos:        sdl3.FPoint,
	mouse_down:       [10]bool,
	mouse_pressed:    [10]bool,
	mouse_released:   [10]bool,

	// UI state
	hot_item_buf:     [256]byte,
	hot_item:         string,
	hot_mouse_button: int,
}
ctx := CTX{}

init_sdl :: proc() -> (ok: bool) {
	if !sdl3.SetAppMetadata("Solitaire", "0.1", "me.bvisness.gamesfolder.solitaire") {
		log.errorf("sdl3.SetAppMetadata failed.")
		return
	}

	if sdl_res := sdl3.Init(sdl3.INIT_VIDEO); !sdl_res {
		log.errorf("sdl3.Init failed.")
		return false
	}

	if !sdl3.CreateWindowAndRenderer(
		"Solitaire",
		i32(WINDOW_SIZE.x),
		i32(WINDOW_SIZE.y),
		sdl3.WindowFlags{},
		&ctx.window,
		&ctx.renderer,
	) {
		log.errorf("sdl3.CreateWindowAndRenderer failed.")
		return false
	}

	return true
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

set_hot :: proc(id: string, hot_mouse_button: int) -> (hover: bool, active: bool) {
	if ctx.hot_item != "" {
		return false, false
	}

	copy_from_string(ctx.hot_item_buf[:], id)
	ctx.hot_item = string(ctx.hot_item_buf[:len(id)])
	ctx.hot_mouse_button = hot_mouse_button
	log.infof("NOW HOT: %s, btn %d", ctx.hot_item, ctx.hot_mouse_button)

	ctx.dirty = true
	return true, true
}

check_hotness :: proc(id: string, rect: sdl3.FRect) -> (hover: bool, active: bool, clicked: int) {
	// If the item is "hot", meaning currently under interaction
	if ctx.hot_item == id {
		release_rect := sdl3.FRect {
			rect.x - CLICK_RELEASE_RADIUS,
			rect.y - CLICK_RELEASE_RADIUS,
			rect.w + 2 * CLICK_RELEASE_RADIUS,
			rect.h + 2 * CLICK_RELEASE_RADIUS,
		}
		if sdl3.PointInRectFloat(ctx.mouse_pos, release_rect) {
			if ctx.mouse_released[ctx.hot_mouse_button] {
				ctx.dirty = true
				return false, false, ctx.hot_mouse_button
			} else {
				return true, true, 0
			}
		}
		return false, false, 0
	}

	// Otherwise, maybe just hover
	hovered := sdl3.PointInRectFloat(ctx.mouse_pos, rect)
	return hovered, false, 0
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
	sdl3.SetRenderDrawColor(ctx.renderer, 19, 127, 49, 255)
	sdl3.RenderClear(ctx.renderer)

	draw_pile(&game_state.deck, DECK_POS, true)
	draw_pile(&game_state.draw_pile, DECK_POS + {CARD_SIZE.x + PILE_GAP, 0}, true)

	for i in 0 ..< 7 {
		pile := &game_state.piles[i]
		pile_pos := V2{GAME_PADDING + f32(i) * (CARD_SIZE.x + PILE_GAP), MAIN_Y}
		draw_pile(pile, pile_pos, false)
		pile_top_pos := pile_pos + {0, bumpage(len(pile) - 1, false)}
		for card, j in game_state.columns[i] {
			draw_card(card, pile_top_pos + {0, f32(j) * COLUMN_SPREAD})
		}
	}
	for i in 0 ..< 4 {
		draw_pile(
			&game_state.foundations[i],
			FOUNDATION_POS + {(CARD_SIZE.x + PILE_GAP) * f32(i), 0},
			true,
		)
	}

	sdl3.RenderPresent(ctx.renderer)
}

draw_card :: proc(card: Card, card_pos: V2) {
	card_rect := sdl3.FRect {
		card_pos.x,
		card_pos.y,
		CARD_NOMINAL_SIZE.x * CARD_SCALE,
		CARD_NOMINAL_SIZE.y * CARD_SCALE,
	}
	card_center := V2{card_rect.x + card_rect.w / 2, card_rect.y + card_rect.h / 2}

	if card.face_up {
		card_variant = 0
		render_texture(&t_card, card_rect)
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
				card_rect.x + PIP_INSET_X,
				card_rect.y + PIP_INSET_Y,
				card_rect.w - PIP_INSET_X * 2,
				card_rect.h - PIP_INSET_Y * 2,
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
		render_texture(&t_card_back, card_rect)
	}
}

bumpage :: proc(n: int, up: bool) -> f32 {
	CARDS_PER_FACEDOWN :: 2
	BUMP_AMT :: 2
	return f32(n / CARDS_PER_FACEDOWN) * BUMP_AMT * (up ? -1 : 1)
}

draw_pile :: proc(pile: ^Pile, pos: V2, up: bool) {
	if len(pile) == 0 {
		return
	}

	top := pile[len(pile) - 1]
	num_remaining := len(pile) - 1

	for i in 0 ..< num_remaining {
		draw_card(Card{face_up = false}, {pos.x, pos.y + bumpage(i, up)})
	}
	draw_card(top, {pos.x, pos.y + bumpage(len(pile) - 1, up)})
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
	free_all(context.temp_allocator)

	loop_context := context
	ctx.t = f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = 0.001 // default to 1ms for the first frame

	// Some jank you have to do in order to continue drawing while resizing the
	// window. https://wiki.libsdl.org/SDL3/AppFreezeDuringDrag
	ok := sdl3.AddEventWatch(proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
			context = (^runtime.Context)(userdata)^
			if event.type == .WINDOW_EXPOSED {
				sdl3.GetWindowSize(ctx.window, &ctx.window_size.x, &ctx.window_size.y)
				frame(false)
			}
			return true
		}, &loop_context)
	if !ok {
		log.error("sdl3.AddEventWatch failed.")
		return
	}

	for !ctx.should_close {
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

		frame(true)
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
	case .MOUSE_MOTION:
		ctx.mouse_pos = {e.motion.x, e.motion.y}
	case .WINDOW_RESIZED:
		sdl3.GetWindowSize(ctx.window, &ctx.window_size.x, &ctx.window_size.y)
		log.infof("Window now has size: %v.", ctx.window_size)
	}
}

frame :: proc(do_input: bool) {
	draw()

	new_t := f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = new_t - ctx.t
	ctx.t = new_t

	// Clear out frame-ephemeral state
	if ctx.mouse_released[ctx.hot_mouse_button] {
		ctx.hot_item = ""
		ctx.hot_mouse_button = 0
	}
	for &pressed in ctx.mouse_pressed {
		pressed = false
	}
	for &released in ctx.mouse_released {
		released = false
	}
}

// ----------------------------------------------------------------------------
// Main

main :: proc() {
	context.logger = log.create_console_logger()

	if res := init_sdl(); !res {
		log.errorf("Initialization failed.")
		os.exit(1)
	}
	defer cleanup()

	load_textures()
	init_game()

	loop()

	log.info("Done.")
}
