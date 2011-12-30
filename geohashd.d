module geohashd;

import tools.base, tools.log, tools.downloader, std.file, std.md5: md5sum = sum;

import tools.ini, std.date, std.process: system;

static import tools.smtp;

alias std.string.toString toString;

extern(C) char* getenv(char* name);

string dateformat(int i) {
  return Format(i<10?"0":"", i);
}

string insertTimes(string s, int d, int m, int y) {
  return s.replace("%Y", Format(y)).replace("%m", Format(m)).replace("%d", Format(d));
}

T strparse(T)(string s) {
  static if (is(string: T)) return s;
  else static if (is(float: T)) return s.atof();
  else static if (is(int: T)) return s.atoi();
  else static if (is(bool: T)) {
    if (s == "y") return true;
    else if (s == "n") return false;
    else throw new Exception("Invalid boolean value: "~s);
  } else static assert(false, "Don't know how to read "~T.stringof);
}

T buf_read(T)(iniFile ifile, arguments args, string name, lazy T orElse) {
  if (auto strp = name in args) {
    return strparse!(T)(*strp);
  }
  T var = ifile.get("", name, orElse);
  ifile.set("", name, var);
  return var;
}

void main(string[] a) {
  auto folder = toString(getenv("HOME".ptr)).sub(".geohash");
  if (!folder.exists()) folder.mkdir();
  auto config = new iniFile(folder.sub("geohash.cfg"));
  auto args = arguments(a);
  if ("help" in args) {
    (&writefln) /multicall
      |args.executable
      |"--home=<home address>"
      |"--maxdist=<max distance>"
      |"--area=<lat,±long>"
      |"--email=<mail>"
      |"--smtpdata=<smtp info>"
      |"--walk=y/n";
    return;
  }
  auto home = buf_read(config, args, "home", {
    writefln("Please enter your home address! ");
    return readln().chomp();
  }());
  auto maxdist = buf_read(config, args, "maxdist", {
    
    writefln("Please enter the maximal distance you are willing to travel (in km)");
    return readln().chomp().atof();
  }());
  string area = buf_read(config, args, "area", {
    writefln("Please enter your lat/long area (xx,±yy)");
    return readln().chomp();
  }());
  string email = buf_read(config, args, "email", {
    writefln("Please enter your EMail address!");
    return readln().chomp();
  }());
  bool walk = buf_read(config, args, "walk", {
    writefln("Do you want to walk there? [y/n]");
    return strparse!(bool)(readln().chomp());
  }());
  string smtpdata = buf_read(config, args, "smtpdata", {
    writefln("Please enter your SMTP server info: username:password@host. ");
    writefln("Be advised that this information will be transmitted unencrypted. ");
    writefln("When in doubt, create a temporary account. ");
    scope(exit) system("reset");
    return readln().chomp();
  }());
  auto currentTime = UTCtoLocalTime(getUTCtime());
  auto lon = area.split(",")[1].atoi();
  if (lon > -30) currentTime -= TicksPerSecond * 60*60 * 24; // 30W change
  auto day = DateFromTime(currentTime), month = MonthFromTime(currentTime) + 1, year = YearFromTime(currentTime);
  auto url = "http://irc.peeron.com/xkcd/map/data/%Y/%m/%d".insertTimes(day, month, year);
  auto opening = url.download();
  auto date = Format(dateformat(year), "-", dateformat(month), "-", dateformat(day));
  logln("Date", (lon > -30)?", including W30":"", ": ", date, " - ", url);
  auto infostring = Format(date, "-", opening);
  ubyte[16] digest;
  md5sum(digest, infostring);
  real toReal(ubyte[] field) {
    ulong ul;
    foreach (value; field) {
      ul = ul * 0x100 + value;
    }
    return (cast(real) ul) / ulong.max;
  }
  auto digest1 = toReal(digest[0..8]), digest2 = toReal(digest[8..16]);

  //                                          remove leading 0
  auto sp = area.split(","), dest = Format(sp[0], Format(digest1)[1 .. $], ",", sp[1], Format(digest2)[1 .. $]);
  if (home.length && (home[0] != '"' || home[$-1] != '"')) home = '"' ~ home ~ '"';
  auto groute = Format("http://maps.google.com/maps?saddr=", home, "&daddr=", dest, "&pw=2", walk?"&dirflg=w":"");
  auto grata = groute.download(); // google route data
  auto dist = grata.between("div\\x3e\\x3cb\\x3e", "\\x26").atof();
  logln(groute, " -> ", dist, " km");
  if (dist > maxdist) { logln("Out of range!"); return; }
  if (dist == 0f) { logln("Too close. Probably a bug. "); return; }
  logln("Within range!");
  auto host = smtpdata; string username, pass;
  auto at = host.find("@");
  if (at != -1) {
    username = host[0 .. at];
    host = host[at+1 .. $];
    auto sep = username.find(":");
    if (sep != -1) {
      pass = username[sep+1 .. $];
      username = username[0 .. sep];
    }
  }
  scope conn = new tools.smtp.Session(host);
  if (username.length) conn.auth_plain(username, pass);
  scope(exit) conn.close;
  conn.compose(email, [email], Format("[geohashd] location within range: ", dist, "km for ", date), Format(
    "A geohashing location has been discovered in your area that is close enough to reach: ", dist, "km!
The link to the Google Maps data is ", groute.htmlEscape(), " . Have fun!"
  ));
}
