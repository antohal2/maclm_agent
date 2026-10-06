# Built-in pets

Scout ships in `scout/pet.json` and `scout/spritesheet.png`.
XcodeGen copies this directory as the `Pets` folder resource, retaining its hierarchy.
The production loader validates both files; missing or invalid art logs an error and uses the Canvas fallback.
