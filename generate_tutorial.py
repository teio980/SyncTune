import os
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, ListFlowable, ListItem
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics

def create_pdf():
    doc = SimpleDocTemplate("SyncTune_Tutorial.pdf", pagesize=letter)
    styles = getSampleStyleSheet()
    
    # Adding a custom style for Chinese text if needed, but we will write in English to ensure it renders correctly
    # on systems without specific CJK fonts configured in ReportLab.
    title_style = styles['Heading1']
    h2_style = styles['Heading2']
    normal_style = styles['Normal']
    
    story = []
    
    # Title
    story.append(Paragraph("SyncTune - User Tutorial & Guide", title_style))
    story.append(Spacer(1, 12))
    
    # Introduction
    story.append(Paragraph("1. Overview", h2_style))
    story.append(Paragraph("SyncTune is a personal, modular music player focused on local MP3 playback and a clean library model, with cloud-ready synchronization. This guide will show you how to set up and use the Android app.", normal_style))
    story.append(Spacer(1, 12))
    
    # Setup
    story.append(Paragraph("2. Getting Started & Permissions", h2_style))
    story.append(Paragraph("• Install and open the SyncTune app on your Android device.", normal_style))
    story.append(Paragraph("• When prompted, grant the media permission (Android 13+ requires READ_MEDIA_AUDIO). This allows the app to find your music.", normal_style))
    story.append(Spacer(1, 12))
    
    # Library
    story.append(Paragraph("3. Managing Your Music Library", h2_style))
    story.append(Paragraph("• Go to the Library tab and tap 'Scan Local Music'.", normal_style))
    story.append(Paragraph("• The app scans your default Music directory (e.g., Music/Artist/Song.mp3).", normal_style))
    story.append(Paragraph("• SyncTune reads ID3 metadata (title, artist, album) and prevents duplicates using an MD5 hash.", normal_style))
    story.append(Spacer(1, 12))
    
    # Playback
    story.append(Paragraph("4. Playback Controls", h2_style))
    story.append(Paragraph("• Tap any song in the Library to start playing.", normal_style))
    story.append(Paragraph("• Use the bottom control bar for quick Play/Pause and Next/Previous actions.", normal_style))
    story.append(Paragraph("• Open the 'Now Playing' screen to access progress seek, shuffle, loop, and playlist controls.", normal_style))
    story.append(Spacer(1, 12))
    
    # Sync Settings
    story.append(Paragraph("5. Cloud Sync Configuration (Google Drive)", h2_style))
    story.append(Paragraph("• Navigate to Settings and toggle 'Cloud Sync' to enable.", normal_style))
    story.append(Paragraph("• Tap 'Music Library Directory' to choose your local sync folder.", normal_style))
    story.append(Paragraph("• Under Developer Mode, enter your Google Drive Client ID, Client Secret, and Refresh Token, then tap 'Save API Credentials'.", normal_style))
    story.append(Spacer(1, 12))
    
    doc.build(story)
    print("PDF successfully generated: SyncTune_Tutorial.pdf")

if __name__ == "__main__":
    create_pdf()