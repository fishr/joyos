//
//  AppController.m
//  vision
//
//  Created by Peter Iannucci on 11/9/09.
//  Copyright __MyCompanyName__ 2009 . All rights reserved.
//

#import "AppController.h"
#import "math.h"
#import "seedfill.h"
#include <sys/ioctl.h>
#include <fcntl.h>
#include <termios.h>

NSFileHandle *open_serial(NSString *path) {
	struct termios options;

	int fildes = open([path cStringUsingEncoding:NSASCIIStringEncoding], O_RDWR | O_NONBLOCK);
	memset(&options,0,sizeof(struct termios));
	cfmakeraw(&options);
	cfsetspeed(&options, 19200);
	options.c_cflag = CREAD | CLOCAL;
	options.c_cflag |= CS8;
	options.c_cc[VMIN] = 0;
	options.c_cc[VTIME] = 10;
	ioctl(fildes, TIOCSETA, &options);
	NSFileHandle *fh = [[NSFileHandle alloc] initWithFileDescriptor:fildes closeOnDealloc:YES];
	
	[fh readInBackgroundAndNotify];
	return fh;
}

void sync_serial(NSFileHandle *fh) {
	const int length=32;
	const int sync_byte=0;
	uint8_t sync[length];
	for (int i=0; i<length; i++)
		sync[i] = sync_byte;
	[fh writeData:[NSData dataWithBytesNoCopy:sync length:length freeWhenDone:NO]];
}

void send_packet(NSFileHandle *fh, void *packet, uint8_t length) {
	@synchronized(fh) {
		[fh writeData:[NSData dataWithBytesNoCopy:&length length:1 freeWhenDone:NO]];
		[fh writeData:[NSData dataWithBytesNoCopy:packet length:length freeWhenDone:NO]];
		usleep(20000);
	}
}

@implementation AppController

- (void) gotDataNotification:(NSNotification *)notification {
	fflush(stdout);
	NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
	[(NSFileHandle*)[NSFileHandle fileHandleWithStandardOutput] writeData:data];
	[serialPort readInBackgroundAndNotify];
}

- (void) awakeFromNib
{
	if(![qcView loadCompositionFromFile:[[NSBundle mainBundle] pathForResource:@"Vision" ofType:@"qtz"]]) {
		NSLog(@"Could not load composition");
	}
	
	serialPort = open_serial(@"/dev/tty.usbserial-A800cBag");
	
	sync_serial(serialPort);
	
	position.type = POSITION;
	position.address = 0xFF;
	generate_goal(&position.payload.coords[1]);
	fill_goal(&position.payload.coords[2], &position.payload.coords[1]);
	fill_goal(&position.payload.coords[3], &position.payload.coords[2]);
	
	
	lights.type = LIGHT;
	lights.address = 0xFF;
	for (int i=0; i<4; i++) {
		lights.payload.lights[i].id = i;
		lights.payload.lights[i].value = 0;
	}

	//for(int i=0; i<sizeof(packet); i++){
	//	printf("%02x",((unsigned char*)&position)[i]);
	//}
	
	//printf("\n");
	//printf("%ld\n", sizeof(board_coord));
	
	[self performSelectorInBackground:@selector(tickThread:) withObject:nil];
	
	[self performSelectorInBackground:@selector(flashThread:) withObject:nil];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(gotDataNotification:) name:NSFileHandleReadCompletionNotification object:nil];
	score = 0;
	timestamp = [[NSDate date] timeIntervalSince1970];
}

- (void) dealloc {
	[serialPort release];
	[super dealloc];
}

void sort(int x[], int y[], int N) {
	int xt, yt;
	for (int i=0; i<N-1; i++) {
		for (int j=i+1; j<N; j++) {
			if (x[i] > x[j]) {
				xt = x[i];
				yt = y[i];
				x[i] = x[j];
				y[i] = y[j];
				x[j] = xt;
				y[j] = yt;
			}
		}
	}
}

// given a bitmap, obtain a location hint
void locate(unsigned char *data, int bytesPerRow, int bytesPerPixel, int width, int height,
			int *xout, int *yout, int *maxout) {
	int max = 0;
	int xmax = 0;
	int ymax = 0;
	for (int y=0; y<height; y++) {
		for (int x=0; x<width; x++) {
			unsigned char value = data[bytesPerPixel * x + bytesPerRow * y];
			if (value > max) {
				max = value;
				xmax = x;
				ymax = y;
			}
		}
	}
	*xout = xmax;
	*yout = ymax;
	*maxout = max;
}

// given a bitmap, blank the masked area in a window
void blank(unsigned char *data, int bytesPerRow, int bytesPerPixel, int width, int height, int x, int y, int dx, int dy) {
	for (int yy=MAX(y,0); yy<MIN(y+dy, height); yy++) {
		for (int xx=MAX(x,0); xx<MIN(x+dx, width); xx++) {
			data[bytesPerPixel * xx + bytesPerRow * yy] = 0;
		}
	}
}

void erase(unsigned char *data, unsigned char *mask, int bytesPerRow, int bytesPerPixel, int width, int height, int x, int y, int dx, int dy) {
	for (int yy=MAX(y,0); yy<MIN(y+dy, height); yy++) {
		for (int xx=MAX(x,0); xx<MIN(x+dx, width); xx++) {
			if (mask[xx*bytesPerPixel + yy*bytesPerRow]) {
				data[xx*bytesPerPixel + yy*bytesPerRow] = 0;
			}
		}
	}
}

void findcentroid(Window *win, unsigned char *data, unsigned char *mask, int bytesPerRow, int bytesPerPixel,
				  float centroid[2], float *sum) {
	float norm = 0.f;
	centroid[0] = 0.f;
	centroid[1] = 0.f;
	for (int y=win->y0; y<=win->y1; y++) {
		for (int x=win->x0; x<=win->x1; x++) {
			if (mask[x*bytesPerPixel + y*bytesPerRow]) {
				float value = data[x*bytesPerPixel + y*bytesPerRow] / 255.f;
				centroid[0] += x*value;
				centroid[1] += y*value;
				norm += value;
			}
		}
	}
	centroid[0] /= norm;
	centroid[1] /= norm;
	*sum = norm;
}

float angle(Window *win, unsigned char *data, unsigned char *mask, int bytesPerRow, int bytesPerPixel,
			float centroid[2]) {
	float xsum = 0.f, ysum = 0.f;
	for (int y=win->y0; y<=win->y1; y++) {
		for (int x=win->x0; x<=win->x1; x++) {
			if (mask[x*bytesPerPixel + y*bytesPerRow]) {
				float mag = sqrt((x-centroid[0])*(x-centroid[0]) + (y-centroid[1])*(y-centroid[1]));
				float value = data[x*bytesPerPixel + y*bytesPerRow] / 255.f;
				xsum += (x-centroid[0])*value/mag;
				ysum += (y-centroid[1])*value/mag;
			}
		}
	}
	return atan2(xsum, ysum);
}

void hist(Window *win, unsigned char *data, unsigned int *h, unsigned int *total, int bytesPerRow, int bytesPerPixel) {
	for (int i=0; i<256; i++)
		h[i] = 0;
	for (int y=win->y0; y<=win->y1; y++) {
		for (int x=win->x0; x<=win->x1; x++) {
			h[data[x*bytesPerPixel + y*bytesPerRow]]++;
		}
	}
	*total = (win->y1 - win->y0 + 1) * (win->x1 - win->x0 + 1);
}

#define R 80
// given a bitmap and a location hint, determine a better location estimate
// and an angle estimate; furthermore, generate a mask
void align(unsigned char *data, unsigned char *mask, int bytesPerRow, int bytesPerPixel, int width, int height,
		   int x, int y, float *xout, float *yout, float *thetaout, bool *light, int *thresh, float *sum) {
	// clear the mask
	blank(mask, bytesPerRow, bytesPerPixel, width, height, x-R, y-R, 2*R+1, 2*R+1);
	// choose a work region
	Window win = {MAX(x-R, 0), MAX(y-R, 0), MIN(x+R, width-1), MIN(y+R, height-1)};
	// choose a threshold by entropy maximization
	unsigned int h[256], hc[256], ht, running = 0;
	int threshold = 0;
	int i=0;
	hist(&win, data, h, &ht, bytesPerRow, bytesPerPixel);
	for (i=0; i<256; i++) {
		hc[i] = running;
		running += h[i];
	}
	for (i=0; i<256; i++) {
		// p is the probability that a randomly chosen pixel has a value >= i
		float p = 1 - (((float)hc[i]) / ht);
		// p should be about 375/ht
		if (p < (375.f / ht) * 2.5) {
			threshold = i;
			break;
		}
	}
	// Now look for pixels more than twice as bright as the threshold
	*light = (ht - hc[80]) > 0;
//	printf("Threshold %d\n", threshold);
//	threshold = data[x*bytesPerPixel + y*bytesPerRow]*2/4;
//	printf("At chosen threshold, p is %.2f rather than %.2f\n", 1 - (((float)h[threshold-1]) / ht), 375.f / ht);

//	fill(x, y, threshold2, &win, data, mask, bytesPerRow, bytesPerPixel);
	// flood fill area above threshold to generate mask (keep bounds)
	//data[x*bytesPerPixel + y*bytesPerRow] * 2 / 4
	fill(x, y, threshold, &win, data, mask, bytesPerRow, bytesPerPixel);
	// within bounds, for masked pixels,
	//   find centroid
	float centroid[2];
	findcentroid(&win, data, mask, bytesPerRow, bytesPerPixel, centroid, sum);
	////	 estimate angle from difference between centroid and center
	//float angle1 = -atan2((win.x1+win.x0)*.5f - centroid[0], (win.y1+win.y0)*.5f - centroid[1]);
	//	 recenter to centroid
	//   integrate angle phasor
	float angle1 = angle(&win, data, mask, bytesPerRow, bytesPerPixel, centroid);
	//   recenter to tail
	//   integrate angle phasor
	//   recenter to head
	//   integrate angle phasor
	//   take a weighted average
	*xout = centroid[0];
	*yout = centroid[1];
	*thetaout = angle1;
	*thresh = threshold;
}

#define N 1
bool firstTick = true;
float oldx[N], oldy[N], oldtheta[N];

float angleDiff(float a, float b) {
	float x = cos(a) - cos(b);
	float y = sin(a) - sin(b);
	return x*x+y*y;
}

int16_t rand_coord(){
	int16_t coord;
	
	do{
		coord = (random()-RAND_MAX/2) / (RAND_MAX / (1<<12));
	} while((coord < -(1<<11)+512) || (coord > (1<<11)-512));
	
	return coord;
}

void generate_goal(board_coord* pos){
	pos->x = rand_coord();
	pos->y = rand_coord() * 3/4;
}

void fill_goal(board_coord* pos, board_coord* last){
	do {
		generate_goal(pos);
	} while (((long)(pos->x-last->x))*((long)(pos->x-last->x)) +
			 ((long)(pos->y-last->y))*((long)(pos->y-last->y)) < (1L << 22));
}

BOOL close_to(board_coord* pos1, board_coord* pos2){
	return ((long)(pos1->x-pos2->x))*((long)(pos1->x-pos2->x)) +
		   ((long)(pos1->y-pos2->y))*((long)(pos1->y-pos2->y)) < (1L << 16); // 6 inches
}

- (void)tickThread:(id)arg {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
	
    for(;;) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
	
    [pool release];
}

- (void)flashThread:(id)arg {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(flash:) userInfo:nil repeats:YES];
	
    for(;;) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
	
    [pool release];
}

- (void)snapTo:(NSValue *)pointer {
	*((NSBitmapImageRep **)[pointer pointerValue]) = [[qcView valueForOutputKey:@"Blurred" ofType:@"NSBitmapImageRep"] copy];
	// createSnapshotImageOfType:@"NSBitmapImageRep"];
}

typedef struct {
	float x, y, theta, sum;
	bool light;
	int max, xmax, ymax, thresh;
} sighting;


#define SWAP(_x_, _y_) {__typeof__(_x_) _z_; _z_=_x_; _x_=_y_; _y_=_z_;}
- (void)tick:(id)arg {
	printf("#");
	if (!qcView.isRendering) {
		score = 0;
		timestamp = [[NSDate date] timeIntervalSince1970];
		return;
	}
	
	double t = [[NSDate date] timeIntervalSince1970] - timestamp;
	t = 120 - t;
	if (t < 0.0) t = 0.0;
	
	double secs = fmod(t, 60.0);
	int mins = (int)(t / 60);
	
	if (firstTick) {
		for (int i=0; i<N; i++)
			oldx[i] = oldy[i] = oldtheta[i] = 0.f;
	}
	
	NSBitmapImageRep* bitmap = 0;
	[self performSelectorOnMainThread:@selector(snapTo:) withObject:[NSValue valueWithPointer:&bitmap] waitUntilDone:YES];
    NSSize imgSize = [bitmap size];
	
	unsigned char *data = [bitmap bitmapData];
	int bytesPerPixel = [bitmap bitsPerPixel] >> 3;
	int bytesPerRow = [bitmap bytesPerRow];

	sighting robot[N];
	
	for (int i=0; i<N; i++) {
		locate(data+1, bytesPerRow, bytesPerPixel,
			   imgSize.width, imgSize.height,
			   &robot[i].xmax, &robot[i].ymax, &robot[i].max);
		
		align(data+1, data+0, bytesPerRow, bytesPerPixel,
			  imgSize.width, imgSize.height,
			  robot[i].xmax, robot[i].ymax,
			  &robot[i].x, &robot[i].y, &robot[i].theta, &robot[i].light, &robot[i].thresh, &robot[i].sum);
		
		erase(data+1, data+0, bytesPerRow, bytesPerPixel,
			  imgSize.width, imgSize.height,
			  robot[i].xmax-R, robot[i].ymax-R, 2*R+1, 2*R+1);
	}
	
	position.payload.coords[0].x = (int16_t)((robot[0].x-320)*(1<<12)/640.);
	position.payload.coords[0].y = -(int16_t)((robot[0].y-240)*(1<<12)/640.);
	position.payload.coords[0].theta = -(int)(robot[0].theta*(1<<12)/(M_PI*2));
	position.payload.coords[0].confidence = robot[0].thresh<<4;
	
	if (close_to(&position.payload.coords[0],&position.payload.coords[1])){
		memmove(position.payload.coords+1, position.payload.coords+2, 2*sizeof(board_coord));
		fill_goal(&position.payload.coords[3], &position.payload.coords[2]);
		if (t > 0.0)
			score++;
	}

	//sync_serial(serialPort);
	send_packet(serialPort,&position,sizeof(packet));
	
	if (firstTick) {
		// number them someway
//		sort(xmax, ymax, N);
	} else {
		// make an effort to figure out which is which
		int pointsToAssign[N], assignments[N];
		int numPointsToAssign = N;
		for (int i=0; i<N; i++)
			pointsToAssign[i] = i;
		for (int i=0; i<N; i++) {
			// figure out which old point corresponds to point i
			// and put it in assignments[i]
			float minDistance = 1e6;
			int minNumber = 0;
			for (int j=0; j<numPointsToAssign; j++) {
				float dx = robot[i].x - oldx[pointsToAssign[j]];
				float dy = robot[i].y - oldy[pointsToAssign[j]];
				float dtheta_squared = angleDiff(robot[i].theta, oldtheta[pointsToAssign[j]]);
				float distance = dx*dx+dy*dy+dtheta_squared*R*R/4.f;
				if (distance<minDistance) {
					minDistance = distance;
					minNumber = j;
				}
			}
			assignments[i] = pointsToAssign[minNumber];
			// remove that point from the list of candidates
			for (int j = minNumber; j<numPointsToAssign-1; j++)
				pointsToAssign[j] = pointsToAssign[j + 1];
			numPointsToAssign--;
		}
		// reassign points according to assignments
		for (int i=0; i<N; i++) {
			int j = assignments[i];
			if (i != j) {
//				printf("Swapping %d %d\n", i, j);
				SWAP(robot[i], robot[j]);
				SWAP(assignments[i], assignments[j]);
			}
		}
	}
	for (int i=0; i<N; i++) {
		oldx[i] = robot[i].x;
		oldy[i] = robot[i].y;
		oldtheta[i] = robot[i].theta;
	}
	
	//NSLog(@"Max was %d", max[0]);
	NSImage *image = [[NSImage alloc] init];
	
	for (int y=0; y<imgSize.height; y++) {
		for (int x=0; x<imgSize.width; x++) {
			if (!data[x*bytesPerPixel + y*bytesPerRow+0]) {
				data[x*bytesPerPixel + y*bytesPerRow+1] = 0;
				data[x*bytesPerPixel + y*bytesPerRow+2] = 0;
				data[x*bytesPerPixel + y*bytesPerRow+3] = 0;
			} else {
				data[x*bytesPerPixel + y*bytesPerRow+1] = 255;
				data[x*bytesPerPixel + y*bytesPerRow+2] = 255;
				data[x*bytesPerPixel + y*bytesPerRow+3] = 255;
			}

			data[x*bytesPerPixel + y*bytesPerRow+0] = 255;
		}
	} 
	
	[image addRepresentation:bitmap];
	
	[imageView setImage: image];
	[image release];
	[bitmap release];
	
	NSMutableArray *robots = [NSMutableArray array];
	NSMutableArray *goals = [NSMutableArray array];
	
	for (int i=0; i<N; i++) {
		float X, Y;
		X = (robot[i].x/imgSize.width)*2.f - 1.f;
		Y = -((robot[i].y/imgSize.height)*2.f - 1.f) * imgSize.height/imgSize.width;

		[robots addObject:[NSDictionary dictionaryWithObjectsAndKeys:
						   [NSNumber numberWithFloat:X], @"X",
						   [NSNumber numberWithFloat:Y], @"Y",
						   [NSNumber numberWithFloat:robot[i].theta*180.f/M_PI], @"Theta",
						   [NSString stringWithFormat:@"Robot %d (%3.1f)", i+1, robot[i].sum/1000.], @"Label", nil]];
		printf("%f\n", robot[i].sum);
	}
	
	for (int i=1; i<4; i++) {
		float X, Y;
		X = (((float)position.payload.coords[i].x*640./(1<<12) + 320)/imgSize.width)*2.f - 1.f;
		Y = -(((-(float)position.payload.coords[i].y*640./(1<<12) + 240)/imgSize.height)*2.f - 1.f) * imgSize.height/imgSize.width;
		[goals addObject:[NSDictionary dictionaryWithObjectsAndKeys:
						   [NSNumber numberWithFloat:X], @"X",
						   [NSNumber numberWithFloat:Y], @"Y",
						   [NSNumber numberWithFloat:0*180.f/M_PI], @"Theta",
						   [NSString stringWithFormat:@"Goal %d", i], @"Label", nil]];
	}

	[qcView setValue:[NSDictionary dictionaryWithObjectsAndKeys:
					  robots, @"Robots",
					  goals, @"Goals",
					  [NSString stringWithFormat:@"Score: %d", score], @"Score",
					  [NSString stringWithFormat:@"Time left: %1d:%06.3f", mins, secs], @"Time",
					  nil] forInputKey:@"Structure"];
	firstTick = false;
}

- (void)flash:(id)unused {
	NSTimeInterval t = [[NSDate date] timeIntervalSinceReferenceDate];
	lights.payload.lights[0].value = (fmod(t*1., 1.0) < .5) ? 255 : 0;
	send_packet(serialPort,&lights,sizeof(packet));
}

- (void)windowWillClose:(NSNotification *)notification {
	[NSApp terminate:self];
}

@end