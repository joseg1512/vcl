# NAC web theme

Theme for **Nube Académica Computacional** (Universidad de Costa Rica).

It follows the same layout as `dropdownmenus` (`page.php`, `css/`, `js/`, `images/`) and replaces the stock VCL red (`#ed1c24`) with the official NAC palette:

| Color | Hex | Use |
| --- | --- | --- |
| Slate | `#4E6A77` | Primary (header type, nav, footer, widgets) |
| Gold | `#F0B91C` | Accents (header/footer bars, hover) |
| Yellow | `#FEDC00` | Highlights |
| Light cyan | `#8FD8F8` | Links/secondary accents |

## Enable the theme

VCL picks the skin from `affiliation.theme` (Site Configuration → **Site Theme**). Available theme names are the directories under `web/themes/`.

1. Copy Dojo's tundra CSS into this theme (required after Dojo is installed under `web/dojo/`):

       cd web/themes
       ./copydojocss.sh nac

   Generated files under `css/dojo/` are gitignored; they must exist on the web server for Dojo widgets.

2. In the VCL UI: **Site Configuration → Site Theme**. Set **Global** (and any other affiliation) to `nac`.

3. Optional — for the login and maintenance pages when no `VCLSKIN` cookie is present, set in `web/.ht-inc/conf.php`:

       define("DEFAULTTHEME", 'nac');

After login, `VCLSKIN` is set from the affiliation theme. Logging out keeps that cookie so the login screen can keep using `nac`.
