package minesweeper

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"

BUTTON_SIZE :: 36
BUTTON_PADDING :: 4

CTX :: struct {
	window:       ^sdl3.Window,
	renderer:     ^sdl3.Renderer,
	should_close: bool,

	// Size
	window_size:  [2]i32,

	// Timing
	t:            f64,
	dt:           f64,
}
ctx := CTX{}

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
	slices      = {272, 460, 1251, 1435},
	slice_scale = 0.05,
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
	load_textures_from_png("resources/minesweeper.png", &flag, &button)

	return true
}

render_texture :: proc(texture: ^Texture, dst: ^sdl3.FRect) {
	assert(texture.tex != nil, "texture was not loaded!")
	src: Maybe(^sdl3.FRect)
	if _, ok := texture.src.?; ok {
		src = &texture.src.?
	}
	scale := texture.slice_scale
	if scale == 0 {
		scale = 1
	}

	switch texture.mode {
	case .NORMAL:
		sdl3.RenderTexture(ctx.renderer, texture.tex, src, dst)
	case .NINESLICE:
		src_rect := texture.src.? or_else texture.rect
		sdl3.RenderTexture9Grid(
			ctx.renderer,
			texture.tex,
			src,
			texture.slices[0] - src_rect.x,
			(src_rect.x + src_rect.w) - texture.slices[1],
			texture.slices[2] - src_rect.y,
			(src_rect.y + src_rect.h) - texture.slices[3],
			scale,
			dst,
		)
	case .NINESLICE_TILED:
		src_rect := texture.src.? or_else texture.rect
		sdl3.RenderTexture9GridTiled(
			ctx.renderer,
			texture.tex,
			src,
			texture.slices[0] - src_rect.x,
			(src_rect.x + src_rect.w) - texture.slices[1],
			texture.slices[2] - src_rect.y,
			(src_rect.y + src_rect.h) - texture.slices[3],
			scale,
			dst,
			scale,
		)
	case:
		trapf("bad render mode: %v", texture.mode)
	}
}

draw :: proc() {
	sdl3.SetRenderDrawColor(ctx.renderer, 255, 255, 255, 255)
	sdl3.RenderClear(ctx.renderer)

	board_rect := sdl3.FRect {
		20,
		20,
		f32(ctx.window_size.x) - 20 * 2,
		f32(ctx.window_size.y) - 20 * 2,
	}
	nrows := int(board_rect.h) / BUTTON_SIZE
	ncols := int(board_rect.w) / BUTTON_SIZE

	for r in 0 ..< nrows {
		for c in 0 ..< ncols {
			rect := sdl3.FRect {
				x = board_rect.x + f32(BUTTON_SIZE * c),
				y = board_rect.y + f32(BUTTON_SIZE * r),
				w = BUTTON_SIZE,
				h = BUTTON_SIZE,
			}
			render_texture(&button, &rect)

			num :=
				numbers[(int(ctx.t - 0.1 * f64(r) - 0.1 * f64(c)) + len(numbers)) % len(numbers)]
			nrect := sdl3.FRect {
				rect.x + BUTTON_PADDING,
				rect.y + BUTTON_PADDING,
				rect.w - BUTTON_PADDING * 2,
				rect.h - BUTTON_PADDING * 2,
			}
			render_texture(&num, &nrect)
		}
	}

	sdl3.RenderPresent(ctx.renderer)
}

cleanup :: proc() {
	sdl3.DestroyWindow(ctx.window)
	sdl3.Quit()
}

process_event :: proc(e: ^sdl3.Event) {
	#partial switch (e.type) {
	case .QUIT:
		ctx.should_close = true
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
}

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
		// Wait for events, then process them all
		e: sdl3.Event
		if !sdl3.WaitEvent(&e) {
			panic("failed sdl3.WaitEvent")
		}
		process_event(&e)
		for sdl3.PollEvent(&e) {
			process_event(&e)
		}

		frame(true)
	}
}

main :: proc() {
	context.logger = log.create_console_logger()

	if res := init_sdl(); !res {
		log.errorf("Initialization failed.")
		os.exit(1)
	}
	defer cleanup()

	loop()

	log.info("Done.")
}
