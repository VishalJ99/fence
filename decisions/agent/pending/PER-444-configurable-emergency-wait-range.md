# PER-444: Configurable emergency-wait range

## Proposed decision

Expose an emergency-unlock wait duration from 1 through 10 whole minutes in Protection settings, defaulting to 3 minutes.

Scale the surprise checkpoint distribution with the selected duration:

- mean: one half of the configured duration;
- standard deviation: one sixth of the configured duration;
- lower bound: 45 seconds;
- upper bound: three seconds before completion.

This preserves the approved 3-minute behavior exactly: mean 90 seconds, standard deviation 30 seconds, clamped to 45 through 177 seconds.

## Why this is pending

The user requested a configurable emergency-unlock time but did not specify a supported range or how the checkpoint distribution should behave for non-default durations. This range is narrow enough to remain a practical emergency path while allowing meaningful control, and proportional sampling preserves the established attention-check shape.

## Alternatives

- Allow a broader range such as 1 through 60 minutes.
- Keep the checkpoint distribution fixed at 90 plus or minus 30 seconds even when the total wait changes.
- Keep the wait fixed at 3 minutes and remove only the emergency-credit balance.
