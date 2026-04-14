package minesweeper

import "core:log"
import "core:math"
import "core:os"

import "vendor:sdl3"

CTX :: struct {
	window:       ^sdl3.Window,
	renderer:     ^sdl3.Renderer,
	should_close: bool,

	// Timing
	t:            f64,
	dt:           f64,
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

	return true
}

draw :: proc() {
	sdl3.SetRenderDrawColor(ctx.renderer, 0, 0, 0, 255)
	sdl3.RenderClear(ctx.renderer)

	x: f32 = 200 + f32(math.sin(ctx.t)) * 100
	y: f32 = 200 + f32(math.sin(ctx.t)) * 100
	rect := sdl3.FRect {
		x = x,
		y = y,
		w = 100,
		h = 40,
	}
	sdl3.SetRenderDrawColor(ctx.renderer, 255, 255, 255, 255)
	sdl3.RenderFillRect(ctx.renderer, &rect)

	sdl3.RenderPresent(ctx.renderer)
}

cleanup :: proc() {
	sdl3.DestroyWindow(ctx.window)
	sdl3.Quit()
}

process_input :: proc() {
	e: sdl3.Event
	for sdl3.PollEvent(&e) {
		#partial switch (e.type) {
		case .QUIT:
			ctx.should_close = true
		}
	}
}

loop :: proc() {
	ctx.t = f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = 0.001 // default to 1ms for the first frame

	for !ctx.should_close {
		process_input()
		draw()

		new_t := f64(sdl3.GetTicksNS()) / 1_000_000_000
		ctx.dt = new_t - ctx.t
		ctx.t = new_t
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
