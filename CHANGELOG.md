# Changelog

## v1.0.1

- The auto scale of the response chart now shows a 60 dB window below the loudest point. Before, a subwoofer roll-off compressed all the curves into a thin strip.
- The charts no longer draw curves outside the plot area.
- The volume sliders no longer show dense tick marks.
- The target curve chart uses the same frequency labels as the other charts.
- The README shows screenshots of the main screens.

## v1.0.0

This is the first public release of AutoREQ.

- The Measure screen shows the transfer function, the phase and the coherence of a speaker with pink noise.
- You can keep snapshots, combine them, and export or import them as CSV files.
- The guided calibration measures each speaker at one or more mic positions.
- The calibration calculates the crossover, the level, the delay, the polarity and the EQ of each speaker.
- Five preset target curves and a custom curve are available.
- The loopback engine applies the correction live to the system audio.
- The Loopback screen has a master volume, a correction strength and a trim for each speaker.
- The app reads REW and miniDSP mic calibration files.
- The app includes approximate curves for the iPhone 17 Pro and iPhone 18 Pro mics.
- The app exports REW filter files, corrected-response CSV files and a results file.
