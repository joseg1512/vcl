<?php
/*
* Licensed to the Apache Software Foundation (ASF) under one or more
* contributor license agreements.  See the NOTICE file distributed with
* this work for additional information regarding copyright ownership.
* The ASF licenses this file to You under the Apache License, Version 2.0
* (the "License"); you may not use this file except in compliance with
* the License.  You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

////////////////////////////////////////////////////////////////////////////////
///
/// \fn getHeader($refresh)
///
/// \param $refresh - bool for adding code to refresh page
///
/// \return string of html to go before the main content
///
/// \brief builds the html that goes before the main content
///
////////////////////////////////////////////////////////////////////////////////
function getHeader($refresh) {
	global $user, $mode, $authed, $locale, $VCLversion;
	$v = $VCLversion;

	$rt  = "<!DOCTYPE html>\n";
	$rt .= "<html lang=\"" . htmlspecialchars($locale, ENT_QUOTES) . "\">\n";
	$rt .= "<head>\n";
	$usenls = 0;
	$usenlsstr = "false";
	if(! preg_match('/^en/', $locale)) {
		$usenls = 1;
		$usenlsstr = "true";
	}
	$rt .= "<link rel=\"shortcut icon\" href=\"themes/nac/images/favicon.svg\" type=\"image/svg+xml\" />\n";
	$rt .= "<link href=\"css/vcl.css\" rel=\"stylesheet\" type=\"text/css\" />\n";

	$rt .= "<meta charset=\"UTF-8\">\n";
	$rt .= "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n";
	$rt .= "<title>" . i('NAC: Nube Académica Computacional') . "</title>\n";
	$rt .= "<meta name='robots' content='noindex,follow' />\n";

	$rt .= "<link href=\"https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css\" rel=\"stylesheet\" integrity=\"sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u\" crossorigin=\"anonymous\" media=\"all\" />\n";

	$rt .= "<script src=\"https://ajax.googleapis.com/ajax/libs/jquery/1.12.4/jquery.min.js\" integrity=\"sha512-jGsMH83oKe9asCpkOVkBnUrDDTp8wl+adkB2D+//JtlxO4SrLoJdhbOysIFQJloQFD+C4Fl1rMsQZF76JjV0eQ==\" crossorigin=\"anonymous\"></script>\n";

	$rt .= "<link href=\"themes/nac/css/theme.css\" rel=\"stylesheet\" type=\"text/css\" />\n";
	$rt .= "<script src=\"themes/nac/js/topnav.js\" type=\"text/javascript\"></script>\n";
	$rt .= "<script src=\"js/code.js?v=$v\" type=\"text/javascript\"></script>\n";
	if($usenls)
		$rt .= "<script type=\"text/javascript\" src=\"js/nls/$locale/messages.js?v=$v\"></script>\n";
	$rt .= "<script type=\"text/javascript\">\n";
	$rt .= "var cookiedomain = '" . COOKIEDOMAIN . "';\n";
	$rt .= "usenls = $usenlsstr;\n";
	$rt .= "</script>\n";
	$rt .= getDojoHTML($refresh);
	if($refresh)
		$rt .= "<noscript><meta http-equiv=refresh content=20></noscript>\n";
	$extracss = getExtraCSS();
	foreach($extracss as $file)
		$rt .= "<link rel=stylesheet type=\"text/css\" href=\"css/$file\">\n";

	$rt .= "</head>\n";
	$rt .= "<body class=\"nac\">\n";
	$rt .= "<div id=\"wrapperdiv\" class=\"container-fluid\">\n";
	$rt .= "<header id=\"siteheader\" role=\"banner\">\n";
	if($authed) {
		$rt .= "  <div id=\"loggedinidbox\">\n";
		$rt .= "    " . htmlspecialchars($user['unityid'] . '@' . $user['affiliation'], ENT_QUOTES) . "\n";
		$rt .= "  </div>\n";
	}
	$rt .= "  <div class=\"container\">\n";
	$rt .= "    <img src=\"themes/nac/images/nac-logo.svg\" class=\"header-logo\" alt=\"" . i('NAC') . "\" />\n";
	$rt .= "    <h1 class=\"site-title\">\n";
	$rt .= "      <span>" . i('Nube Académica Computacional') . "</span><br />\n";
	$rt .= "      <small>" . i('Universidad de Costa Rica') . "</small>\n";
	$rt .= "    </h1>\n";
	$rt .= "  </div><!-- .container -->\n";
	$rt .= "  <div class=\"container-fluid\">\n";
	$rt .= "      <div id=\"above-site-navigation\"></div>\n";
	$rt .= "      <nav id=\"site-navigation\" class=\"navbar navbar-default\" role=\"navigation\">\n";
	$rt .= "        <a class=\"skip-link screen-reader-text\" href=\"#content\">" . i('Skip to content') . "</a>\n";
	$rt .= "        <div class=\"container\">\n";
	$rt .= "          <div class=\"navbar-header\">\n";
	$rt .= "            <button id=\"navmenubtn\" type=\"button\" class=\"navbar-toggle\" data-toggle=\"collapse\" data-target=\"#navbar-collapse-main\">\n";
	$rt .= "              <span class=\"sr-only\">" . i('Toggle navigation') . "</span>\n";
	$rt .= "              <span class=\"icon-bar\"></span>\n";
	$rt .= "              <span class=\"icon-bar\"></span>\n";
	$rt .= "              <span class=\"icon-bar\"></span>\n";
	$rt .= "            </button>\n";
	$rt .= "          </div><!-- .navbar-header -->\n";
	$rt .= "          <div class=\"navbar-collapse collapse\" id=\"navbar-collapse-main\">\n";
	$rt .= "            <div id=\"rightmenubox\">\n";
	if($mode != 'inmaintenance')
		$rt .= getSelectLanguagePulldown();
	if($authed) {
		$rt .= "              <span id=\"logoutlink1\"><a href=\"" . BASEURL . SCRIPT . "?mode=logout\">" . i('Log out') . "</a></span>\n";
	}
	$rt .= "            </div>\n"; # rightmenubox
	$rt .= "            <ul id=\"topmenu\" class=\"nav navbar-nav\">\n";

	if($authed) {
		$menu = getNavMenuData();
		uasort($menu, 'sortMenuList');

		if($menu['reservations']['selected'])
			$rt .= "              <li class=\"active\"><a href=\"{$menu['reservations']['url']}\">{$menu['reservations']['title']}</a></li>\n";
		else
			$rt .= "              <li><a href=\"{$menu['reservations']['url']}\">{$menu['reservations']['title']}</a></li>\n";
		$rt .= "              <li><a href=\"#\" class=\"dropdown-toggle\" data-toggle=\"dropdown\" data-target=\"#\">" . i('Manage') . "<b class=\"caret\"></b></a>\n";
		$rt .= "                <ul class=\"dropdown-menu\">\n";
		foreach($menu as $page => $item) {
			if(in_array($page, array('dashboard', 'statistics', 'reservations', 'home', 'authentication', 'codeDocumentation', 'userLookup')))
				continue;
			$selected = '';
			if($item['selected'])
				$selected = ' class="active"';
			$rt .= "                  <li$selected><a href=\"{$item['url']}\">{$item['title']}</a></li>\n";
		}
		$rt .= "                </ul>\n";
		$rt .= "              </li>\n";
		$rt .= "              <li><a href=\"#\" class=\"dropdown-toggle\" data-toggle=\"dropdown\" data-target=\"#\">" . i('Reporting') . "<b class=\"caret\"></b></a>\n";
		$rt .= "                <ul class=\"dropdown-menu\">\n";
		$items = array('dashboard', 'statistics', 'userLookup');
		foreach($items as $item) {
			if(! isset($menu[$item]))
				continue;
			$selected = '';
			if($menu[$item]['selected'])
				$selected = ' class="active"';
			$rt .= "                  <li$selected><a href=\"{$menu[$item]['url']}\">{$menu[$item]['title']}</a></li>\n";
		}
		$rt .= "                </ul>\n";
		$rt .= "              </li>\n";
		$rt .= "              <li><a href=\"{$menu['codeDocumentation']['url']}\">{$menu['codeDocumentation']['title']}</a></li>\n";
	}

	if($mode != 'inmaintenance') {
		$langitems = getThemeLanguageMenuItems();
		if(! empty($langitems)) {
			$rt .= "              <li id=\"mobilelanguagemenu\"><a href=\"#\" class=\"dropdown-toggle\" data-toggle=\"dropdown\" data-target=\"#\">" . i('Language') . "<b class=\"caret\"></b></a>\n";
			$rt .= "                <ul class=\"dropdown-menu\">\n";
			foreach($langitems as $item) {
				$selected = '';
				if($item['selected'])
					$selected = ' class="active"';
				$rt .= "                  <li$selected><a href=\"{$item['url']}\">{$item['label']}</a></li>\n";
			}
			$rt .= "                </ul>\n";
			$rt .= "              </li>\n";
		}
	}

	if(! $authed && $mode != 'selectauth' && $mode != 'submitLogin' &&  $mode != 'inmaintenance')
		$rt .= "              <li><a href=\"" . BASEURL . SCRIPT . "?mode=selectauth\">" . i('Log in') . "</a></li>\n";
	elseif($authed)
		$rt .= "              <li id=\"logoutlink2\"><a href=\"" . BASEURL . SCRIPT . "?mode=logout\">" . i('Log out') . "</a></li>\n";
	$rt .= "            </ul>\n";
	$rt .= "          </div><!-- /.navbar-collapse -->\n";
	$rt .= "        </div><!-- .container -->\n";
	$rt .= "      </nav><!-- #site-navigation -->\n";
	$rt .= "    </div><!-- .container-fluid -->\n";
	$rt .= "  </header><!-- #siteheader -->\n";
	$rt .= "	 <main id=\"main\" role=\"main\">\n";
	$rt .= "<div id=\"content\">\n";
	return $rt;
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn sortMenuList($a, $b)
///
/// \param $a - first item
/// \param $b - second item
///
/// \return -1 if $a['title'] < $b['title'], 0 if $a['title'] == $b['title'],
/// 1 if $a['title'] > $b['title']
///
/// \brief sorts navigation menu items by title
///
////////////////////////////////////////////////////////////////////////////////
function sortMenuList($a, $b) {
	return strcmp($a['title'], $b['title']);
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn getFooter()
///
/// \return string of html to go after the main content
///
/// \brief builds the html that goes after the main content
///
////////////////////////////////////////////////////////////////////////////////
function getFooter() {
	$rt = "";
	$rt .= "</div><!-- #content -->\n";
	$rt .= "  </main><!-- #main -->\n";
	$rt .= "  <div class=\"container-fluid\">\n";
	$rt .= "    <footer role=\"contentinfo\">\n";
	$rt .= "      <div class=\"row\">\n";
	$rt .= "        <div class=\"site-info\">\n";
	$rt .= i('Nube Académica Computacional') . " &#183; " . i('Universidad de Costa Rica') . "<br />\n";
	$rt .= "          Copyright &copy; " . date('Y') . " &#183; ";
	$rt .= "<img src=\"themes/nac/images/feather_tiny.png\" alt=\"\">";
	$rt .= "<a href=\"https://vcl.apache.org\">Apache Software Foundation</a>";
	$rt .= "        </div><!-- .site-info -->\n";
	$rt .= "      </div><!-- .row -->\n";
	$rt .= "    </footer>\n";
	$rt .= "  </div><!-- .container-fluid -->\n";
	$rt .= "</div><!-- #wrapperdiv -->\n";
	$rt .= "<script src=\"https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/js/bootstrap.min.js\" integrity=\"sha384-Tc5IQib027qvyjSMfHjOMaLkfuWVxZxUPnCJA7l2mCWNIpG9mGCD8wGNIcPD7Txa\" crossorigin=\"anonymous\"></script>\n";
	$rt .= "</body>\n";
	$rt .= "</html>\n";
	return $rt;
}
?>
