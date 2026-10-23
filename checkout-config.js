// The one switch for the whole checkout (payments SB-10.1: the values the two sides exchange are the backend addresses, the success
// address, the cancel address and the allowed origins). OFF until the owner's apply has printed the three test-mode addresses; turning it
// on is a reviewed change that also adds the same three origins to connect-src in _headers. No secret, no price and no key ever lives here.
window.FOSTERPAY_CONFIG = { enabled: false, checkout: "", entitlement: "", resend: "" };
