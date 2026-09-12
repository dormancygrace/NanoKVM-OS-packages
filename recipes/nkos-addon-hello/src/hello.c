#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void stop(int signal_number)
{
	(void) signal_number;
	running = 0;
}

int main(int argc, char **argv)
{
	int daemon_mode = argc > 1 && strcmp(argv[1], "--daemon") == 0;
	if (!daemon_mode) {
		puts("NanoKVM hello addon");
		return 0;
	}
	signal(SIGTERM, stop);
	signal(SIGINT, stop);
	while (running) {
		puts("hello");
		fflush(stdout);
		sleep(30);
	}
	return 0;
}
