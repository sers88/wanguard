// trace-ubus.uc — step-by-step of iface_map's path in the live lab
import * as ubus from 'ubus';
import * as fs from 'fs';

print("socket access: ", fs.access('/var/run/ubus.sock'), "\n");
let conn = ubus.connect();
print("connect: ", conn != null, "\n");

let lst = conn.list();
print("list type: ", type(lst), " len: ", length(lst), "\n");
print("list[0]: ", lst[0], "\n");
printf("list[0] JSON: %J\n", lst[0]);

let found = false;
for (let o in lst)
	if (o == 'network.interface')
		found = true;
print("found network.interface: ", found, "\n");

let dump = conn.call('network.interface', 'dump', {});
print("dump type: ", type(dump), "\n");
if (dump != null) {
	print("dump.interface len: ", length(dump.interface ?? []), "\n");
	printf("first rec: %J\n", (dump.interface ?? [])[0]);
}
