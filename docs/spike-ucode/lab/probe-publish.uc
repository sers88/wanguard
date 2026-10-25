// probe-publish.uc — does this ubus.so support publishing objects?
import * as ubus from 'ubus';
let conn = ubus.connect();
if (conn == null) {
	print("no ubusd\n");
	exit(1);
}
print("methods: ", join(",", sort(keys(conn))), "\n");
