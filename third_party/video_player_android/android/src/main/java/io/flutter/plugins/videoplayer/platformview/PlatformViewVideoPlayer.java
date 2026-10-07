// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.platformview;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoAsset;
import io.flutter.plugins.videoplayer.VideoPlayer;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;
import io.flutter.plugins.videoplayer.VideoPlayerOptions;
import io.flutter.view.TextureRegistry.SurfaceProducer;

/**
 * A subclass of {@link VideoPlayer} that adds functionality related to platform view as a way of
 * displaying the video in the app.
 */
public class PlatformViewVideoPlayer extends VideoPlayer {
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @VisibleForTesting
  public PlatformViewVideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    super(events, mediaItem, options, /* surfaceProducer */ null, exoPlayerProvider);
  }

  /**
   * Creates a platform view video player.
   *
   * @param context application context.
   * @param events event callbacks.
   * @param asset asset to play.
   * @param options options for playback.
   * @return a video player instance.
   */
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @NonNull
  public static PlatformViewVideoPlayer create(
      @NonNull Context context,
      @NonNull VideoPlayerCallbacks events,
      @NonNull VideoAsset asset,
      @NonNull VideoPlayerOptions options) {
    return new PlatformViewVideoPlayer(
        events,
        asset.getMediaItem(),
        options,
        () -> {
          ExoPlayer.Builder builder = new ExoPlayer.Builder(context);
          if (options.backBufferDurationMs != null) {
            if (options.backBufferDurationMs < 0) {
              throw new IllegalArgumentException("backBufferDurationMs must be at least 0");
            }
            if (options.backBufferDurationMs > 0) {
              // Clamp the value to ensure it fits within the int range expected by
              // DefaultLoadControl.
              int backBufferInt =
                  (int) Math.min(options.backBufferDurationMs.longValue(), Integer.MAX_VALUE);
              DefaultLoadControl loadControl =
                  new DefaultLoadControl.Builder()
                      .setBackBuffer(backBufferInt, /* retainBackBufferFromKeyframe= */ true)
                      .build();
              builder.setLoadControl(loadControl);
            }
          }
          androidx.media3.exoplayer.trackselection.DefaultTrackSelector trackSelector =
              new androidx.media3.exoplayer.trackselection.DefaultTrackSelector(context);
          // TEMPORARY A/B diagnostic, round 2 — round 1 (disabling this
          // whole block) confirmed it's the actual cause of multiview/
          // mini-player audio bleed-through reported after the AC3 fix.
          // This round isolates WHICH part: constructing an explicit
          // DefaultRenderersFactory at all (even with extension mode left
          // at its OFF default, i.e. hardware-only, no FFmpeg fallback),
          // vs. specifically turning the extension mode on. If this build
          // (factory present, extension mode untouched) also bleeds
          // through, the mere act of passing an explicit factory to each
          // instance is the cause, not the FFmpeg extension specifically.
          DefaultRenderersFactory renderersFactory =
              new DefaultRenderersFactory(context);
          builder
              .setTrackSelector(trackSelector)
              .setMediaSourceFactory(asset.getMediaSourceFactory(context))
              .setRenderersFactory(renderersFactory);
          return builder.build();
        });
  }

  @NonNull
  @Override
  protected ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer) {
    return new PlatformViewExoPlayerEventListener(exoPlayer, videoPlayerEvents);
  }
}
