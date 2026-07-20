#import <Cocoa/Cocoa.h>

// Renders a 1024x1024 macOS app icon: a gradient squircle with the
// four-directional drag-scroll arrows (matching the menu bar symbol).

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: make_icon <out.png>\n");
            return 1;
        }
        NSString *outPath = [NSString stringWithUTF8String:argv[1]];

        const CGFloat S = 1024;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
                          bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                               isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                            bytesPerRow:0 bitsPerPixel:0];

        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];

        [[NSColor clearColor] set];
        NSRectFill(NSMakeRect(0, 0, S, S));

        // Rounded-rect "squircle" with margin, per macOS icon grid.
        CGFloat margin = 92;
        NSRect box = NSMakeRect(margin, margin, S - 2 * margin, S - 2 * margin);
        CGFloat radius = box.size.width * 0.2237;
        NSBezierPath *rr = [NSBezierPath bezierPathWithRoundedRect:box
                                                          xRadius:radius
                                                          yRadius:radius];

        // Drop shadow behind the tile.
        [NSGraphicsContext saveGraphicsState];
        NSShadow *tileShadow = [[NSShadow alloc] init];
        tileShadow.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.30];
        tileShadow.shadowBlurRadius = 34;
        tileShadow.shadowOffset = NSMakeSize(0, -16);
        [tileShadow set];
        [[NSColor blackColor] set];
        [rr fill];
        [NSGraphicsContext restoreGraphicsState];

        // Clip to the tile for the gradient + highlight + glyph.
        [NSGraphicsContext saveGraphicsState];
        [rr addClip];

        NSColor *top = [NSColor colorWithSRGBRed:0.20 green:0.52 blue:1.00 alpha:1.0];
        NSColor *bottom = [NSColor colorWithSRGBRed:0.36 green:0.20 blue:0.90 alpha:1.0];
        NSGradient *grad = [[NSGradient alloc] initWithStartingColor:top endingColor:bottom];
        [grad drawInRect:box angle:-90];

        // Soft top highlight for a little depth.
        NSGradient *hl = [[NSGradient alloc] initWithColorsAndLocations:
            [[NSColor whiteColor] colorWithAlphaComponent:0.22], 0.0,
            [[NSColor whiteColor] colorWithAlphaComponent:0.0], 0.55, nil];
        [hl drawInRect:box angle:-90];

        // Four-directional arrows glyph, tinted white.
        if (@available(macOS 11.0, *)) {
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:430
                                                               weight:NSFontWeightSemibold];
            NSImage *sym = [NSImage imageWithSystemSymbolName:@"arrow.up.and.down.and.arrow.left.and.right"
                                     accessibilityDescription:nil];
            sym = [sym imageWithSymbolConfiguration:cfg];
            NSSize ss = sym.size;

            NSImage *tinted = [[NSImage alloc] initWithSize:ss];
            [tinted lockFocus];
            [sym drawAtPoint:NSZeroPoint fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver fraction:1.0];
            [[NSColor whiteColor] set];
            NSRectFillUsingOperation(NSMakeRect(0, 0, ss.width, ss.height),
                                     NSCompositingOperationSourceAtop);
            [tinted unlockFocus];

            NSRect dr = NSMakeRect((S - ss.width) / 2, (S - ss.height) / 2,
                                   ss.width, ss.height);
            [NSGraphicsContext saveGraphicsState];
            NSShadow *glyphShadow = [[NSShadow alloc] init];
            glyphShadow.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.22];
            glyphShadow.shadowBlurRadius = 18;
            glyphShadow.shadowOffset = NSMakeSize(0, -8);
            [glyphShadow set];
            [tinted drawInRect:dr fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];

            fprintf(stderr, "glyph size: %.0f x %.0f\n", ss.width, ss.height);
        }

        [NSGraphicsContext restoreGraphicsState];  // clip
        [NSGraphicsContext restoreGraphicsState];  // context

        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:outPath atomically:YES]) {
            fprintf(stderr, "failed to write %s\n", argv[1]);
            return 1;
        }
        fprintf(stderr, "wrote %s\n", argv[1]);
    }
    return 0;
}
