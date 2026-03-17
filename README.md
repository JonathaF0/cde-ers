# CDE-ERS Setup

## How It Works

ERS's `c_functions.lua` (client) already fires `TriggerServerEvent` for all
events (pullover, pursuit, NPC interaction, callouts). CDE-ERS registers
handlers for these server events.

No modifications to night_ers files are needed — the default ERS
`c_functions.lua` already forwards all events.

## Verification

After `ensure cde-ers`, do a callout AND a pullover. Check server console for:

```
[CDE-ERS] EVENT >> OnAcceptedCalloutOffer (source=20)
[CDE-ERS] EVENT >> OnPullover (source=20)
[CDE-ERS] EVENT >> OnFirstNPCInteraction (source=20)
```

The `EVENT >>` lines show every ERS event that reaches the server, regardless
of whether CDE-ERS processes it. If an event doesn't appear, ERS isn't firing
it from `c_functions.lua`.

## Troubleshooting: Pullover Events Not Firing

If callout events work but pullover events don't appear in the `EVENT >>` log:

1. Check your ERS `c_functions.lua` has the OnPullover function with
   `TriggerServerEvent('ErsIntegration::OnPullover', pedData, vehicleData)`
2. Check ERS config to ensure pullovers are enabled
3. Ensure the pullover interaction is completing (approach vehicle, initiate stop)
