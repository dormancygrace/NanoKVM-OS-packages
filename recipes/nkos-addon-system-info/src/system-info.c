#include <stdio.h>
#include <string.h>
#include <sys/utsname.h>

int main(int argc, char **argv)
{
	struct utsname system;
	int json = argc > 1 && strcmp(argv[1], "--json") == 0;
	if (uname(&system) != 0)
		return 1;
	if (json) {
		printf("{\"sysname\":\"%s\",\"release\":\"%s\",\"machine\":\"%s\"}\n",
		       system.sysname, system.release, system.machine);
	} else {
		printf("sysname=%s\nrelease=%s\nmachine=%s\n",
		       system.sysname, system.release, system.machine);
	}
	return 0;
}
