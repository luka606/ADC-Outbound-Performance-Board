// Keep the original qualification acceptance fixtures reproducible across dates/timezones.
exports.freezeClock=function(scope,instant='2026-09-23T20:00:00.000Z'){const NativeDate=scope.Date;scope.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[instant]));}static now(){return NativeDate.parse(instant);}};};
