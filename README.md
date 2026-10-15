# Memory Aquarium

This PC's RAM as a pixel-art fish tank.

- **Water level** is memory in use; the air above it is what's free.
- **Each fish is an app**, sized by its private memory (all of its processes together).
  The twelve biggest swim on their own; the rest form a school of small fry.
  Apps hogging more than 8% of RAM puff up with spikes.
- **Sludge on the bottom** is the kernel's non-paged pool (memory drivers lock in RAM).
  Above 1.5 GB it turns toxic and skulls bubble up: a sign of a leaking driver.
- Past 85% the fish sweat and gasp; past 92% the tank overflows.
- Hover anything for numbers. Click a fish to reel it in, which ends all of that app's
  processes after you confirm. Windows' own processes can't be caught.

`sampler.py` (standard library only) reads the numbers via Win32 every 2 s and writes a JSON
snapshot that the Godot app polls. It exits on its own when the aquarium closes.

## Run

```
C:\Tools\Godot\Godot_v4.7.1-stable_win64.exe --path C:\Users\Arda\sandbox\memory-aquarium
```

Needs Python 3 on PATH (`pythonw` or `python`).
