package minesweeper

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"

GAME_PADDING :: 20
FACE_BAR_HEIGHT :: 50

BUTTON_SIZE :: 36
BUTTON_PADDING :: 4
MAX_ROWS, MAX_COLS :: 20, 40

// This is just what SDL does I guess
MOUSE_LEFT :: 1
MOUSE_RIGHT :: 3
CLICK_RELEASE_RADIUS :: 20

// ----------------------------------------------------------------------------
// Game logic

game_arena_buf: [4 * mem.Megabyte]byte
game_arena: mem.Arena
game_allocator: runtime.Allocator

GameState :: struct {
	board_size: [2]int,
	board:      []Cell,
	generated:  bool,
	win_state:  WinState,
}
game_state := GameState{}

CellProperty :: enum {
	REVEALED, // whether the player has revealed the cell
	MINE, // whether the cell has a mine
	FLAG, // whether the cell has been flagged
	QUESTION, // whether the cell has been question-marked
}

Cell :: bit_set[CellProperty;u8]

WinState :: enum {
	IN_PROGRESS,
	WIN,
	LOSE,
}

get_window_rect :: proc() -> sdl3.FRect {
	return sdl3.FRect{0, 0, f32(ctx.window_size.x), f32(ctx.window_size.y)}
}

get_board_rect :: proc() -> sdl3.FRect {
	return sdl3.FRect {
		GAME_PADDING,
		GAME_PADDING + FACE_BAR_HEIGHT + GAME_PADDING,
		f32(ctx.window_size.x) - GAME_PADDING * 2,
		f32(ctx.window_size.y) - GAME_PADDING * 3 - FACE_BAR_HEIGHT,
	}
}

new_game :: proc() {
	free_all(game_allocator)

	board_rect := get_board_rect()
	ncols := int(board_rect.w) / BUTTON_SIZE
	nrows := int(board_rect.h) / BUTTON_SIZE

	game_state = GameState {
		board_size = {ncols, nrows},
		board      = make([]Cell, nrows * ncols, game_allocator),
		generated  = false,
	}
}

generate_board :: proc(start_r, start_c: int) {
	for r in 0 ..< game_state.board_size.y {
		for c in 0 ..< game_state.board_size.x {
			cell := get_cell(r, c)
			close_to_start := abs(r - start_r) <= 1 && abs(c - start_c) <= 1
			if rand.float32() > 0.8 && !close_to_start {
				cell^ += {.MINE}
			}
		}
	}
	game_state.generated = true
}

get_cell :: proc(row, col: int) -> ^Cell {
	return &game_state.board[row * game_state.board_size.x + col]
}

count_mines :: proc(row, col: int) -> int {
	num_mines := 0
	for roff in -1 ..= 1 {
		for coff in -1 ..= 1 {
			r := row + roff
			c := col + coff
			row_ok := 0 <= r && r < game_state.board_size.y
			col_ok := 0 <= c && c < game_state.board_size.x
			if row_ok && col_ok && .MINE in get_cell(r, c) {
				num_mines += 1
			}
		}
	}
	assert(0 <= num_mines && num_mines <= 9)
	return num_mines
}

reveal :: proc(row, col: int) {
	if (row < 0 || game_state.board_size.y <= row) || (col < 0 || game_state.board_size.x <= col) {
		return
	}
	cell := get_cell(row, col)

	if .REVEALED in cell {
		return
	}
	cell^ += {.REVEALED}

	if .MINE in cell {
		// kerblam!
		game_state.win_state = .LOSE
	} else {
		num_mines := count_mines(row, col)
		if num_mines == 0 {
			for roff in -1 ..= 1 {
				for coff in -1 ..= 1 {
					reveal(row + roff, col + coff)
				}
			}
		}
	}
}

check_win :: proc() {
	// The game is won when all non-mine cells are revealed, and all mine cells are flagged.
	all_revealed := true
	all_flagged := true
	for &cell in game_state.board {
		if .MINE not_in cell && .REVEALED not_in cell {
			all_revealed = false
		}
		if .MINE in cell && .FLAG not_in cell {
			all_flagged = false
		}
	}
	if all_revealed && all_flagged {
		game_state.win_state = .WIN
	}
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
	slices:      [4]f32, // left, right, top, bottom, relative to original img
	slice_scale: f32,

	// Filled in when loading
	tex:         ^sdl3.Texture,
	rect:        sdl3.FRect,
}

button := Texture {
	mode        = .NINESLICE,
	src         = sdl3.FRect{210, 1183, 523 - 210, 1496 - 1183},
	slices      = {62, 63, 68, 61},
	slice_scale = 0.05,
}
button_active := Texture {
	mode        = .NINESLICE,
	src         = sdl3.FRect{210, 1533, 523 - 210, 1846 - 1533},
	slices      = {62, 63, 68, 61},
	slice_scale = 0.05,
}
empty_cell := Texture {
	src = sdl3.FRect{215, 1888, 521 - 215, 2192 - 1888},
}
background := Texture {
	mode        = .NINESLICE_TILED,
	src         = sdl3.FRect{234, 1904, 506 - 234, 2176 - 1904},
	slice_scale = 0.2,
}

numbers := []Texture {
	{src = sdl3.FRect{570, 284, 200, 200}}, // 1
	{src = sdl3.FRect{820, 284, 200, 200}}, // 2
	{src = sdl3.FRect{1070, 284, 200, 200}}, // 3
	{src = sdl3.FRect{570, 534, 200, 200}}, // 4
	{src = sdl3.FRect{820, 534, 200, 200}}, // 5
	{src = sdl3.FRect{1070, 534, 200, 200}}, // 6
	{src = sdl3.FRect{570, 784, 200, 200}}, // 7
	{src = sdl3.FRect{820, 784, 200, 200}}, // 8
}

flag := Texture {
	src = sdl3.FRect{1070, 784, 200, 200},
}
question := Texture {
	src = sdl3.FRect{570, 1034, 200, 200},
}
mine := Texture {
	src = sdl3.FRect{820, 1034, 200, 200},
}

face_normal := Texture {
	src = sdl3.FRect{1533, 303, 1823 - 1533, 586 - 303},
}
face_active := Texture {
	src = sdl3.FRect{1979, 298, 2306 - 1979, 573 - 298},
}
face_win := Texture {
	src = sdl3.FRect{1512, 676, 1812 - 1512, 963 - 676},
}
face_lose := Texture {
	src = sdl3.FRect{1994, 656, 2320 - 1994, 998 - 656},
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
	if !sdl3.SetAppMetadata("Minesweeper", "0.1", "me.bvisness.gamesfolder.minesweeper") {
		log.errorf("sdl3.SetAppMetadata failed.")
		return
	}

	if sdl_res := sdl3.Init(sdl3.INIT_VIDEO); !sdl_res {
		log.errorf("sdl3.Init failed.")
		return false
	}

	if !sdl3.CreateWindowAndRenderer(
		"Minesweeper",
		400,
		400,
		sdl3.WindowFlags{.RESIZABLE},
		&ctx.window,
		&ctx.renderer,
	) {
		log.errorf("sdl3.CreateWindowAndRenderer failed.")
		return false
	}

	load_texture_slice_from_png("resources/minesweeper.png", &numbers)
	load_textures_from_png(
		"resources/minesweeper.png",
		&button,
		&button_active,
		&empty_cell,
		&background,
		&flag,
		&question,
		&mine,
		&face_normal,
		&face_active,
		&face_win,
		&face_lose,
	)

	return true
}

init_game :: proc() {
	mem.arena_init(&game_arena, game_arena_buf[:])
	game_allocator = mem.arena_allocator(&game_arena)
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
		tex.rect = sdl3.FRect{0, 0, f32(surface.w), f32(surface.h)}
	}
}

load_texture_slice_from_png :: proc(path: string, textures: ^[]Texture) {
	ptrs := make([]^Texture, len(textures), context.temp_allocator)
	for _, i in ptrs {
		ptrs[i] = &textures[i]
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

draw :: proc() {
	sdl3.SetRenderDrawColor(ctx.renderer, 255, 255, 255, 255)
	sdl3.RenderClear(ctx.renderer)

	render_texture(&background, get_window_rect())

	face := &face_normal
	if game_state.win_state == .WIN {
		face = &face_win
	} else if game_state.win_state == .LOSE {
		face = &face_lose
	} else if strings.has_prefix(ctx.hot_item, "cell") && ctx.hot_mouse_button == MOUSE_LEFT {
		face = &face_active
	}
	face_pos := [2]f32{f32(ctx.window_size.x) / 2, GAME_PADDING + FACE_BAR_HEIGHT / 2}
	FACE_SCALE :: 0.02
	face_rect := sdl3.FRect {
		face_pos.x - face.rect.w * FACE_SCALE / 2,
		face_pos.y - face.rect.h * FACE_SCALE / 2,
		face.rect.w * FACE_SCALE,
		face.rect.h * FACE_SCALE,
	}
	render_texture(face, face_rect)

	board_rect := get_board_rect()
	for c in 0 ..< game_state.board_size.x {
		for r in 0 ..< game_state.board_size.y {
			id := fmt.tprintf("cell:%d,%d", r, c)

			cell := get_cell(r, c)
			num_mines := count_mines(r, c)

			rect := sdl3.FRect {
				x = board_rect.x + f32(BUTTON_SIZE * c),
				y = board_rect.y + f32(BUTTON_SIZE * r),
				w = BUTTON_SIZE,
				h = BUTTON_SIZE,
			}
			nrect := sdl3.FRect {
				rect.x + BUTTON_PADDING,
				rect.y + BUTTON_PADDING,
				rect.w - BUTTON_PADDING * 2,
				rect.h - BUTTON_PADDING * 2,
			}

			hover, active, clicked := false, false, 0
			if game_state.win_state == .IN_PROGRESS && .REVEALED not_in cell {
				hover, active, clicked = check_hotness(id, rect)
			}
			if hover &&
			   ctx.mouse_pressed[MOUSE_LEFT] &&
			   .FLAG not_in cell &&
			   .QUESTION not_in cell {
				hover, active = set_hot(id, MOUSE_LEFT)
			} else if hover && ctx.mouse_pressed[MOUSE_RIGHT] {
				set_hot(id, MOUSE_RIGHT)
				hover = false // I don't want to render the active state for right clicks
				active = false
			}
			if clicked == MOUSE_LEFT && .REVEALED not_in cell {
				if !game_state.generated {
					generate_board(r, c)
				}
				reveal(r, c)
			} else if clicked == MOUSE_RIGHT {
				if .FLAG in cell {
					cell^ -= {.FLAG}
					cell^ += {.QUESTION}
				} else if .QUESTION in cell {
					cell^ -= {.QUESTION}
				} else {
					cell^ += {.FLAG}
				}
			}

			if .REVEALED in cell {
				render_texture(&empty_cell, rect)
				if .MINE in cell {
					render_texture(&mine, nrect)
				} else if num_mines > 0 {
					num := numbers[num_mines - 1]
					render_texture(&num, nrect)
				}
			} else {
				render_texture(active ? &button_active : &button, rect)
				if .FLAG in cell {
					render_texture(&flag, nrect)
				} else if .MINE in cell && game_state.win_state == .LOSE {
					render_texture(&mine, nrect)
				} else if .QUESTION in cell {
					render_texture(&question, nrect)
				}
			}
		}
	}

	sdl3.RenderPresent(ctx.renderer)
}

render_texture :: proc(texture: ^Texture, dst: sdl3.FRect) {
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
		sdl3.RenderTexture(ctx.renderer, texture.tex, src, &dst)
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
				new_game()
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
		new_game()
		log.infof("Window now has size: %v.", ctx.window_size)
	}
}

frame :: proc(do_input: bool) {
	draw()
	check_win()

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

	init_game()

	loop()

	log.info("Done.")
}
