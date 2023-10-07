/**
	Support for GitLab repositories.

	Copyright: © 2015-2016 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.gitlab;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
import std.string : startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;
import vibe.textfilter.urlencode;


class GitLabRepositoryProvider : RepositoryProvider {
	private {
		string m_token;
		string m_url;
	}

	private this(string token, string url)
	{
		m_token = token;
		m_url = url;
	}

	static void register(string auth_token, string url)
	{
		addRepositoryProvider("gitlab", new GitLabRepositoryProvider(auth_token, url));
	}

	bool parseRepositoryURL(URL url, out DbRepository repo)
	@safe {
		import std.algorithm.iteration : map;
		import std.algorithm.searching : endsWith;
		import std.array : join;
		import std.conv : to;

		string host = url.host;
		if (!host.endsWith(".gitlab.com") && host != "gitlab.com" && host != "gitlab")
			return false;

		repo.kind = "gitlab";

		auto path = url.path.relativeTo(InetPath("/")).bySegment;
		if (path.empty)
			throw new Exception("Invalid Repository URL (no path)");
		if (path.front.name.empty)
			throw new Exception("Invalid Repository URL (missing owner)");
		repo.owner = path.front.name.to!string;
		path.popFront;
		if (path.empty || path.front.name.empty)
			throw new Exception("Invalid Repository URL (missing project)");

		repo.project = path.map!"a.name".join("/");

		// Allow any number of segments, as GitLab's subgroups can be nested
		return true;
	}

	unittest {
		import std.exception : assertThrown;

		auto h = new GitLabRepositoryProvider(null, "https://gitlab.com/");
		DbRepository r;
		assert(!h.parseRepositoryURL(URL("https://github.com/foo/bar"), r));
		assert(h.parseRepositoryURL(URL("https://gitlab.com/foo/bar"), r));
		assert(r == DbRepository("gitlab", "foo", "bar"));
		assert(h.parseRepositoryURL(URL("https://gitlab.com/group/subgroup/subsubgroup/project"), r));
		assert(r == DbRepository("gitlab", "group", "subgroup/subsubgroup/project"));
		assertThrown(h.parseRepositoryURL(URL("http://gitlab.com/foo/"), r));
		assertThrown(h.parseRepositoryURL(URL("http://gitlab.com/"), r));
	}

	Repository getRepository(DbRepository repo)
	@safe {
		return new GitLabRepository(repo.owner, repo.project, m_token, m_url.length ? URL(m_url) : URL("https://gitlab.com/"));
	}
}

class GitLabRepository : Repository {
@safe:

	private {
		string m_owner;
		string m_projectPath;
		URL m_baseURL;
		string m_authToken;
	}

	this(string owner, string projectPath, string auth_token, URL base_url)
	{
		m_owner = owner;
		m_projectPath = projectPath;
		m_authToken = auth_token;
		m_baseURL = base_url;
	}

	RefInfo[] getTags()
	{
		import std.datetime.systime : SysTime;

		Json tags;
		try tags = readJson(getAPIURLPrefix()~"repository/tags?private_token="~m_authToken);
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag["name"].get!string;
				auto commit = tag["commit"]["id"].get!string;
				auto date = SysTime.fromISOExtString(tag["commit"]["committed_date"].get!string);
				ret ~= RefInfo(tagname, commit, date);
				logDebug("Found tag for %s/%s: %s", m_owner, m_projectPath, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag["name"].get!string~": "~e.msg);
			}
		}
		return ret;
	}

	RefInfo[] getBranches()
	{
		import std.datetime.systime : SysTime;

		Json branches = readJson(getAPIURLPrefix()~"repository/branches?private_token="~m_authToken);
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch["name"].get!string;
			auto commit = branch["commit"]["id"].get!string;
			auto date = SysTime.fromISOExtString(branch["commit"]["committed_date"].get!string);
			ret ~= RefInfo(branchname, commit, date);
			logDebug("Found branch for %s/%s: %s", m_owner, m_projectPath, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		RepositoryInfo ret;
		auto nfo = readJson(getAPIURLPrefix()~"?private_token="~m_authToken);
		ret.isFork = false; // not reported by API
		ret.stats.stars = nfo["star_count"].opt!uint; // might mean watchers for Gitlab
		ret.stats.forks = nfo["forks_count"].opt!uint;
		ret.stats.issues = nfo["open_issues_count"].opt!uint;
		return ret;
	}

	RepositoryFile[] listFiles(string commit_sha, InetPath path)
	{
		import std.uri : encodeComponent;
		assert(path.absolute, "Passed relative path to listFiles.");
		auto penc = () @trusted { return encodeComponent(path.toString()[1..$]); } ();
		auto url = getAPIURLPrefix()~"repository/tree?path="~penc~"&ref="~commit_sha;
		auto ls = readJson(url).get!(Json[]);
		RepositoryFile[] ret;
		ret.reserve(ls.length);
		foreach (entry; ls) {
			string type = entry["type"].get!string;
			RepositoryFile file;
			if (type == "tree") {
				file.type = RepositoryFile.Type.directory;
			}
			else if (type == "blob") {
				file.type = RepositoryFile.Type.file;
			}
			else continue;
			file.commitSha = commit_sha;
			file.path = InetPath("/" ~ entry["path"].get!string);
			ret ~= file;
		}
		return ret;
	}

	void readFile(string commit_sha, InetPath path, scope void delegate(scope InputStream) @safe reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto penc = path.toString()[1..$].urlEncode;
		auto url = getAPIURLPrefix() ~ "repository/files/" ~ penc ~ "/raw?ref=" ~ commit_sha ~ "&private_token="~ m_authToken;
		downloadCached(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if (m_authToken.length > 0) return null; // public download URL doesn't work
		return getRawDownloadURL(ver);
	}

	void download(string ver, scope void delegate(scope InputStream) @safe del)
	{
		auto url = getRawDownloadURL(ver);
		url ~= "&private_token="~m_authToken;
		downloadCached(url, del);
	}

	private string getRawDownloadURL(string ver)
	{
		import std.uri : encodeComponent;
		if (ver.startsWith("~")) ver = ver[1 .. $];
		else ver = ver;
		auto venc = () @trusted { return encodeComponent(ver); } ();
		// The "sha" parameter in GitLab's API v4 accepts the tag, branch or the  the commit sha (see https://docs.gitlab.com/ee/api/repositories.html#get-file-archive)
		return getAPIURLPrefix() ~ "repository/archive.zip?sha="~venc;
	}

	private string getAPIURLPrefix()
	{
		return m_baseURL.toString() ~ "api/v4/projects/" ~ (m_owner ~ "/" ~ m_projectPath).urlEncode ~ "/";
	}
}
