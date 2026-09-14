/*
 * Aity Drive desktop client theme (Branding, ADR 0001).
 * Copyright (C) 2026 AITY CLOUD SRL
 *
 * Compiled into the upstream ownCloud client via the OEM theme mechanism
 * (THEME.cmake -> OEM.cmake -> THEME_INCLUDE); the upstream sources stay
 * untouched. Licensed under the GNU General Public License version 2 or
 * later, like the client it themes.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#pragma once

#include "common/depreaction.h"
#include "resources/resources.h"
#include "common/utility.h"
#include "common/version.h"
#include "theme.h"

#include <QColor>
#include <QIcon>
#include <QString>

// AITY_SERVER_URL is injected per Environment build by the overlay's
// OEM.cmake (add_compile_definitions): https://drive.aity.tech for
// production, https://drive.aity.works for staging.
#ifndef AITY_SERVER_URL
#error "AITY_SERVER_URL must be defined by the OEM theme's OEM.cmake"
#endif

namespace OCC {

/**
 * No Q_OBJECT on purpose: this header is compiled only through
 * theme.cpp's `#include THEME_INCLUDE`, so it never passes through moc.
 * Nothing needs the subclass's own metaobject.
 */
class AityDriveTheme : public Theme
{
public:
    AityDriveTheme()
        : Theme()
    {
    }

    // Locks the wizard to the Environment's Drive URL; a non-empty value
    // also hides the server URL entry (appconfig.cpp:
    // _allowServerURLChange = overrideServerUrlV2().isEmpty()).
    OC_DISABLE_DEPRECATED_WARNING
    QString overrideServerUrl() const override
    {
        return QStringLiteral(AITY_SERVER_URL);
    }
    OC_ENABLE_DEPRECATED_WARNING

    // Public PKCE client per the identity table in
    // meta/specs/aity-drive-v1.md; no secret. The loopback redirect
    // (http://127.0.0.1:* / http://localhost:*) stays upstream-default.
    QString oauthClientId() const override
    {
        return QStringLiteral("drive-desktop");
    }

    QString oauthClientSecret() const override
    {
        return QString();
    }

    QString helpUrl() const override
    {
        return QStringLiteral("https://aity.ro/contacteaza-ne/");
    }

    // Brand red-600 header with white title and the white wizard mark
    // (meta/brand palette).
    QColor wizardHeaderBackgroundColor() const override
    {
        return QColor(0xb8, 0x08, 0x18);
    }

    QColor wizardHeaderTitleColor() const override
    {
        return QColor(0xff, 0xff, 0xff);
    }

    QIcon wizardHeaderLogo() const override
    {
        return Resources::themeUniversalIcon(QStringLiteral("wizard_logo"));
    }

    // The About page. Upstream's names its authors, links central.owncloud.com
    // and carries the ownCloud GmbH copyright as the headline. Ours leads with
    // the product and AITY CLOUD SRL; the upstream attribution stays, in the
    // small print at the bottom, because GPLv2 section 2(c) keeps an accurate
    // legal notice reachable and the copyright on the code is theirs.
    QString about() const override
    {
        return tr("<p>%1 version %2.</p>"
                  "<p>Help and account: <a href=\"https://%3\">https://%3</a></p>"
                  "<p>Copyright &copy; 2026 AITY CLOUD SRL. %1 and the Aity logo are trademarks of AITY CLOUD SRL.</p>"
                  "<p><small>Open source: %1 is built on the ownCloud desktop client, &copy; ownCloud GmbH, "
                  "licensed under the GNU General Public License version 2. Complete corresponding source: "
                  "<a href=\"https://github.com/aity-cloud/drive-desktop\">github.com/aity-cloud/drive-desktop</a></small></p>"
                  "<p><small>%4</small></p>")
            .arg(Utility::escape(appNameGUI()), Utility::escape(Version::displayString()),
                Utility::escape(QStringLiteral(APPLICATION_DOMAIN)), aboutVersions(Theme::VersionFormat::RichText));
    }

    // No github.com/owncloud commit links behind the build hash.
    bool aboutShowCopyright() const override { return false; }
};

} // namespace OCC
