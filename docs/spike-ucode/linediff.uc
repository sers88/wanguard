import * as fs from 'fs';
let a = fs.readfile(ARGV[0]);
let b = fs.readfile(ARGV[1]);
let la = split(a, "\n");
let lb = split(b, "\n");
for (let i = 0; i < length(la); i++) {
	if (la[i] == lb[i])
		printf('%d: len %d same\n', i + 1, length(la[i]));
	else
		printf('%d: DIFF sh=<%s> (%d) ucode=<%s> (%d)\n', i + 1, la[i], length(la[i]), lb[i], length(lb[i]));
}
