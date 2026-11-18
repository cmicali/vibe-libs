// The driver for a build without libFuzzer, such as Xcode's clang: each
// argument is a file, or a folder whose files run in name order. Each input
// runs once, so a sanitizer report fails the run.

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size);

static int RunFile(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "replay: cannot open %s\n", path);
        return 1;
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    uint8_t *bytes = malloc(size > 0 ? (size_t)size : 1);
    size_t read = fread(bytes, 1, (size_t)size, file);
    fclose(file);
    fprintf(stderr, "replay: %s\n", path);
    LLVMFuzzerTestOneInput(bytes, read);
    free(bytes);
    return 0;
}

static int Compare(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(int argc, char **argv) {
    int failures = 0, runs = 0;
    for (int i = 1; i < argc; i++) {
        struct stat info;
        if (stat(argv[i], &info) != 0) {
            fprintf(stderr, "replay: no such input %s\n", argv[i]);
            failures++;
            continue;
        }
        if (!S_ISDIR(info.st_mode)) {
            failures += RunFile(argv[i]);
            runs++;
            continue;
        }
        DIR *dir = opendir(argv[i]);
        char **names = NULL;
        size_t count = 0;
        for (struct dirent *entry; dir && (entry = readdir(dir));) {
            if (entry->d_name[0] == '.') {
                continue;
            }
            names = realloc(names, (count + 1) * sizeof *names);
            asprintf(&names[count++], "%s/%s", argv[i], entry->d_name);
        }
        if (dir) {
            closedir(dir);
        }
        qsort(names, count, sizeof *names, Compare);
        for (size_t n = 0; n < count; n++) {
            failures += RunFile(names[n]);
            runs++;
            free(names[n]);
        }
        free(names);
    }
    fprintf(stderr, "replay: %d inputs, %d unreadable\n", runs, failures);
    return failures ? 1 : 0;
}
