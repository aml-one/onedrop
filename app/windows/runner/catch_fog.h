#ifndef RUNNER_CATCH_FOG_H_
#define RUNNER_CATCH_FOG_H_

// Native layered catch fog. Flutter's GPU view cannot punch a color-key,
// so the glow is drawn here with per-pixel alpha (UpdateLayeredWindow).
void CatchFogShow(bool locked);
void CatchFogHide();

#endif  // RUNNER_CATCH_FOG_H_
