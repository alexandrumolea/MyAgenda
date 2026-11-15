// Four MyAgenda icon concepts, each in a light and a dark variant.
// 1024×1024 artwork; the home screen applies the squircle mask.
const ICONS = {
  spread: {
    name: "Open Agenda",
    why: "The two-page landscape spread, like a paper agenda lying open on the desk, with one line of gel ink.",
    svg(dark) {
      const bg = dark ? ["#1B2433", "#0B0F17"] : ["#3D9BFF", "#0A6CF0"];
      const left = dark ? "#3A4558" : "#FFFFFF";
      const right = dark ? "#2F3848" : "#E9F1FF";
      const ink = dark ? "#5AB0FF" : "#0A84FF";
      const dots = dark ? "#3B4558" : "#B9CCEA";
      let d = "";
      for (let r = 0; r < 4; r++) for (let c = 0; c < 3; c++)
        d += `<circle cx="${590 + c * 70}" cy="${410 + r * 70}" r="9" fill="${dots}"/>`;
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${bg[0]}"/><stop offset="1" stop-color="${bg[1]}"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#g)"/>
<g transform="translate(512 512) scale(1.2) translate(-512 -543)">
<path d="M512 330 C 420 290 300 285 196 318 L 196 742 C 300 712 420 716 512 756 Z" fill="${left}"/>
<path d="M512 330 C 604 290 724 285 828 318 L 828 742 C 724 712 604 716 512 756 Z" fill="${right}"/>
<path d="M512 330 L 512 756" stroke="${dark ? "#0B0F17" : "#0A6CF0"}" stroke-opacity=".25" stroke-width="6"/>
${d}
<path d="M262 452 C 300 420 330 470 356 440 C 380 412 402 466 430 438" fill="none" stroke="${ink}" stroke-width="22" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M262 540 C 296 516 326 560 352 534 C 372 514 392 548 418 528 C 432 518 446 526 456 532" fill="none" stroke="${ink}" stroke-width="22" stroke-linecap="round" stroke-linejoin="round" opacity=".55"/>
<path d="M262 626 C 292 604 316 640 342 618" fill="none" stroke="${ink}" stroke-width="22" stroke-linecap="round" stroke-linejoin="round" opacity=".55"/>
</g>
</svg>`;
    }
  },
  gel: {
    name: "Gel a",
    why: "One continuous gel-pen stroke on dotted paper. The lowercase a is the pen, the paper and the name in one mark.",
    svg(dark) {
      const bg = dark ? ["#16181D", "#0A0B0E"] : ["#FFFFFF", "#EEF2F8"];
      const dot = dark ? "#2C313B" : "#CBD3DF";
      const ink = dark ? "#4FA8FF" : "#0A84FF";
      let d = "";
      for (let r = 0; r < 7; r++) for (let c = 0; c < 7; c++)
        d += `<circle cx="${152 + c * 120}" cy="${152 + r * 120}" r="10" fill="${dot}"/>`;
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${bg[0]}"/><stop offset="1" stop-color="${bg[1]}"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#g)"/>
${d}
<path d="M650 430 C 612 352 500 338 428 392 C 346 454 334 594 400 652 C 466 710 590 676 632 580 C 652 534 658 474 660 404 C 656 500 650 580 664 640 C 676 692 720 712 776 680" fill="none" stroke="${ink}" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;
    }
  },
  week: {
    name: "Today",
    why: "The date strip from the top of every page: seven days, today in blue, and your own handwriting underneath.",
    svg(dark) {
      const bg = dark ? ["#1A1C21", "#0C0D10"] : ["#FFFFFF", "#F1F4F9"];
      const day = dark ? "#3A3F4A" : "#C8D0DC";
      const blue = dark ? "#4FA8FF" : "#0A84FF";
      const ink = dark ? "#E6E8EC" : "#1C1C1E";
      let d = "";
      for (let i = 0; i < 7; i++) {
        const x = 212 + i * 100;
        d += i === 4
          ? `<circle cx="${x}" cy="300" r="30" fill="${blue}"/><rect x="${x - 30}" y="356" width="60" height="16" rx="8" fill="${blue}"/>`
          : `<circle cx="${x}" cy="300" r="18" fill="${day}"/>`;
      }
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${bg[0]}"/><stop offset="1" stop-color="${bg[1]}"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#g)"/>
${d}
<rect x="170" y="420" width="684" height="4" fill="${day}"/>
<path d="M200 530 C 250 486 290 566 340 520 C 384 480 410 556 456 520 C 500 486 528 548 572 522 C 610 500 640 540 676 520 C 720 496 752 536 800 512" fill="none" stroke="${ink}" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M200 650 C 246 610 284 684 330 640 C 370 602 400 668 444 636 C 486 606 516 660 560 632" fill="none" stroke="${ink}" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
<circle cx="226" cy="772" r="28" fill="none" stroke="${blue}" stroke-width="16"/>
<path d="M300 772 C 336 742 364 796 400 766 C 430 740 452 788 488 764" fill="none" stroke="${ink}" stroke-width="30" stroke-linecap="round" stroke-linejoin="round" opacity=".45"/>
</svg>`;
    }
  },
  ribbon: {
    name: "Ribbon",
    why: "A warm paper page, a blue bookmark ribbon where you left off, and a hand-drawn check for what is done.",
    svg(dark) {
      const bg = dark ? ["#24221E", "#141310"] : ["#FFF8DF", "#F8EBC0"];
      const ribbon = dark ? "#3D9BFF" : "#0A84FF";
      const ribbonShade = dark ? "#1F6FD1" : "#0868CC";
      const ink = dark ? "#F2EEE4" : "#1C1C1E";
      const line = dark ? "#3A362E" : "#E9D9A4";
      let l = "";
      for (let i = 0; i < 5; i++) l += `<rect x="150" y="${300 + i * 120}" width="724" height="6" rx="3" fill="${line}"/>`;
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${bg[0]}"/><stop offset="1" stop-color="${bg[1]}"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#g)"/>
${l}
<path d="M676 0 L 676 470 L 738 412 L 800 470 L 800 0 Z" fill="${ribbon}"/>
<path d="M676 0 L 676 60 L 800 60 L 800 0 Z" fill="${ribbonShade}"/>
<path d="M266 566 C 300 598 340 650 372 690 C 420 590 500 470 600 382" fill="none" stroke="${ink}" stroke-width="58" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;
    }
  }
};
if (typeof module !== "undefined") module.exports = ICONS;
